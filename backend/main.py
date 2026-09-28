import asyncio
import hmac
import json
import os
import re
import sys
import threading
import time
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

# Windows 콘솔 기본 인코딩(cp949)이 한글 로그의 em-dash 등을 못 받아써서
# 요청 처리 중 서버가 죽었다. 프린트문마다 고치는 대신 stdout 자체를 UTF-8로
# 고정해 이 클래스의 크래시를 통째로 없앤다.
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

import google.auth
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from google import genai
from google.api_core.exceptions import NotFound
from google.auth.transport.requests import Request
from google.cloud import firestore, storage
from google.genai import errors as genai_errors
from google.genai import types
from pydantic import BaseModel

from prompts import (
    DEFAULT_PROMPT_TEMPLATE,
    DEFAULT_PROMPT_VERSION,
    EMPTY_RESULT,
    RESPONSE_SCHEMA,
)

# 이보다 짧은 녹음은 Gemini를 부르지 않는다 — 대화라 부를 만한 게 담기기엔
# 너무 짧아서, 모델이 애매한 잡음을 그럴듯한 응급상황으로 지어내는 원인이었다.
# 0.1초 무음도 모델이 소리를 지어냈으므로 모델을 바꿔도 이 가드는 유지한다.
MIN_AUDIO_SECONDS = 2

load_dotenv(Path(__file__).parent / ".env")


def _require_env(name: str) -> str:
    """설정값은 코드에 박지 않는다. 빠졌으면 요청을 받기 전에 바로 멈춘다."""
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"환경변수 {name}이(가) 설정되지 않았습니다")
    return value


PROJECT_ID = _require_env("PROJECT_ID")
REGION = _require_env("REGION")  # 버킷·Firestore·Cloud Run 리전
BUCKET = _require_env("BUCKET")
MODEL = _require_env("MODEL")  # 별칭(gemini-flash-latest 등) 말고 모델 ID를 그대로
# Vertex AI 호출 리전. REGION과 분리해 두어, 비상 전환 시 코드 수정 없이
# VERTEX_LOCATION·MODEL만 바꿔 재배포한다.
VERTEX_LOCATION = _require_env("VERTEX_LOCATION")
if VERTEX_LOCATION == "global":
    # global은 처리 리전을 보장하지 않아 "특정 리전에서 처리한다"고 말할 수 없다.
    raise SystemExit("VERTEX_LOCATION=global은 사용하지 않습니다 — 리전을 명시하세요")
# 앱만 부르게 하는 공유 토큰 — 무단 호출 방지용 최소 보호일 뿐 보안 인증이 아니다
# (APK에서 추출할 수 있는 값이다).
APP_TOKEN = _require_env("APP_TOKEN")
# Signed URL 서명 주체. Cloud Run에서는 런타임 서비스 계정이 자동으로 잡히므로
# 비워 두고, 로컬(사용자 계정 ADC)에서만 rapid-backend 서비스 계정을 적는다.
SIGNER_EMAIL = os.environ.get("SIGNER_EMAIL", "").strip()

# onset 절대시각 계산용. Cloud Run은 UTC로 돌기 때문에 시간대를 명시해야 한다.
KST = ZoneInfo("Asia/Seoul")

# 서버가 객체 이름을 정한다. 앱이 보낸 MIME은 허용 목록으로만 확장자에 대응시킨다.
AUDIO_TYPES = {"audio/mp4": "m4a", "audio/wav": "wav"}
PHOTO_TYPES = {"image/jpeg": "jpg", "image/png": "png"}
MAX_PHOTOS = 3
MAX_AUDIO_BYTES = 50 * 1024 * 1024
MAX_PHOTO_BYTES = 10 * 1024 * 1024
SIGNED_URL_TTL = timedelta(minutes=10)
SESSION_ID = re.compile(r"[0-9a-f]{32}")
AUDIO_NAME = re.compile(r"audio\.(m4a|wav)")
PHOTO_NAME = re.compile(r"photo-[0-2]\.(jpg|png)")

# 앱 타임아웃(90초)보다 짧게 두어, 서버가 먼저 이유 있는 에러를 만들게 한다.
# 재시도까지 포함한 전체 한도다 — 시도마다 75초를 주면 최악 225초가 된다.
VERTEX_DEADLINE_SECONDS = 75
MAX_RETRIES = 2  # 503(과부하)는 흔히 발생 — 최대 2회 재시도
RETRY_DELAY_SECONDS = 1.5

# 프롬프트 수정은 캐시 TTL(1분) 내 반영된다.
PROMPT_CACHE_SECONDS = 60

GENERATION_CONFIG = types.GenerateContentConfig(
    # 온도를 낮춰서 대화에 없는 내용을 그럴듯하게 채워 넣는 것(hallucination)을
    # 최대한 억제한다 — 이 작업은 창의성이 아니라 정확한 인용이 목적이다.
    temperature=0,
    # 대화 듣고 정해진 스키마 채우는 작업이라 추론이 필요 없다. thinking을 켜 두면
    # max_output_tokens가 thinking에 먼저 소모되어 MAX_TOKENS로 빈 응답이 나올 수 있다.
    thinking_config=types.ThinkingConfig(thinking_budget=0),
    response_mime_type="application/json",
    response_schema=RESPONSE_SCHEMA,
    # 8필드 한국어 + reasons 배열이 여유 있게 들어가는 크기.
    max_output_tokens=4096,
    # 도구 호출을 쓰지 않는다.
    automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True),
)

storage_client = storage.Client(project=PROJECT_ID)
bucket = storage_client.bucket(BUCKET)
firestore_client = firestore.AsyncClient(project=PROJECT_ID)
genai_client = genai.Client(vertexai=True, project=PROJECT_ID, location=VERTEX_LOCATION)

# Cloud Run에는 서명용 개인키가 없다. ADC 액세스 토큰으로 IAM signBlob을 불러
# 서명한다(서비스 계정이 자기 자신에 대해 serviceAccountTokenCreator 필요).
_credentials, _ = google.auth.default(
    scopes=["https://www.googleapis.com/auth/cloud-platform"]
)
_credentials_lock = threading.Lock()

app = FastAPI()


class AnalysisFailed(Exception):
    """분석 실패 — 앱에 돌려줄 코드·문구와 메타데이터용 분류를 함께 담는다."""

    def __init__(self, status: int, detail: str, error_type: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail
        self.error_type = error_type


def _signing_identity() -> tuple[str, str]:
    """서명에 쓸 (서비스 계정 이메일, 액세스 토큰)을 돌려준다."""
    with _credentials_lock:
        if not _credentials.valid:
            _credentials.refresh(Request())
        token = _credentials.token
    # Compute Engine 자격증명은 refresh 전까지 이메일이 "default"로 남는다.
    email = SIGNER_EMAIL or getattr(_credentials, "service_account_email", "")
    if not email or email == "default":
        raise RuntimeError("서명할 서비스 계정을 알 수 없습니다 — 로컬에서는 SIGNER_EMAIL을 설정하세요")
    return email, token


def _signed_put(name: str, mime: str, max_bytes: int, email: str, token: str) -> dict:
    # Content-Type과 용량 상한을 서명에 묶어, 앱이 다른 형식·큰 파일을 올리면
    # GCS가 거부하게 한다. 앱은 headers를 그대로 붙여 PUT해야 한다.
    headers = {"x-goog-content-length-range": f"0,{max_bytes}"}
    url = bucket.blob(name).generate_signed_url(
        version="v4",
        method="PUT",
        expiration=SIGNED_URL_TTL,
        content_type=mime,
        # 라이브러리가 넘긴 dict에 Host를 끼워 넣으므로 사본을 준다.
        headers=dict(headers),
        service_account_email=email,
        access_token=token,
    )
    return {
        "object": name,
        "url": url,
        "method": "PUT",
        "headers": {"Content-Type": mime, **headers},
    }


def require_app_token(x_rapid_token: str = Header(default="")) -> None:
    """무단 호출 방지용 최소 보호 — 앱과 공유한 토큰이 맞는지만 본다."""
    if not hmac.compare_digest(x_rapid_token.encode(), APP_TOKEN.encode()):
        raise HTTPException(401, "인증 실패")


@app.get("/api/health")
async def health():
    """앱이 백엔드를 찾았는지 확인하는 용도. 비밀값은 노출하지 않는다."""
    return {"ok": True, "model": MODEL, "vertex_location": VERTEX_LOCATION}


class UploadRequest(BaseModel):
    audio_mime: str
    photo_mimes: list[str] = []


@app.post("/api/uploads", dependencies=[Depends(require_app_token)])
async def create_uploads(req: UploadRequest):
    """세션 ID와 객체 이름을 서버가 정해 PUT용 Signed URL을 발급한다.

    앱이 이름을 정하게 두면 다른 세션의 객체를 덮어쓰거나 지울 수 있으므로,
    이름은 항상 서버가 만든다. 이어올리기(resumable)는 아직 없고 단순 PUT이다.
    """
    audio_ext = AUDIO_TYPES.get(req.audio_mime)
    if not audio_ext:
        raise HTTPException(400, f"허용하지 않는 오디오 형식: {req.audio_mime}")
    if len(req.photo_mimes) > MAX_PHOTOS:
        raise HTTPException(400, f"사진은 최대 {MAX_PHOTOS}장입니다")
    for mime in req.photo_mimes:
        if mime not in PHOTO_TYPES:
            raise HTTPException(400, f"허용하지 않는 사진 형식: {mime}")

    session_id = uuid.uuid4().hex
    prefix = f"sessions/{session_id}"

    def sign_all() -> dict:
        email, token = _signing_identity()
        return {
            "audio": _signed_put(
                f"{prefix}/audio.{audio_ext}", req.audio_mime, MAX_AUDIO_BYTES, email, token
            ),
            "photos": [
                _signed_put(
                    f"{prefix}/photo-{i}.{PHOTO_TYPES[mime]}", mime, MAX_PHOTO_BYTES, email, token
                )
                for i, mime in enumerate(req.photo_mimes)
            ],
        }

    started = time.perf_counter()
    try:
        # 서명마다 IAM signBlob 네트워크 호출이 나가므로 이벤트 루프를 막지 않게 한다.
        urls = await asyncio.to_thread(sign_all)
    except Exception as e:
        print(f"[uploads] 서명 실패: {e!r}")
        raise HTTPException(500, "업로드 주소 발급 실패")
    sign_ms = round((time.perf_counter() - started) * 1000)
    print(f"[uploads] session={session_id} photos={len(req.photo_mimes)} sign_ms={sign_ms}")

    return {
        "session_id": session_id,
        "expires_at": (datetime.now(KST) + SIGNED_URL_TTL).isoformat(timespec="seconds"),
        **urls,
    }


_prompt_cache: tuple[float, str, str] | None = None


async def _load_prompt() -> tuple[str, str]:
    """Firestore prompts/current에서 (템플릿, 버전)을 읽는다. 1분간 캐시한다.

    Firestore를 못 읽어도 분석 자체가 멈추면 안 되므로 내장 기본 프롬프트로
    대신하고 버전을 "builtin"으로 남긴다.
    """
    global _prompt_cache
    now = time.monotonic()
    if _prompt_cache and now - _prompt_cache[0] < PROMPT_CACHE_SECONDS:
        return _prompt_cache[1], _prompt_cache[2]

    template, version = DEFAULT_PROMPT_TEMPLATE, DEFAULT_PROMPT_VERSION
    try:
        snap = await firestore_client.collection("prompts").document("current").get(timeout=5)
        data = snap.to_dict() if snap.exists else None
        if data and data.get("template"):
            template = data["template"]
            version = str(data.get("version", "unknown"))
        else:
            print("[prompt] 경고: prompts/current 문서가 없어 내장 기본 프롬프트를 쓴다")
    except Exception as e:
        print(f"[prompt] 경고: Firestore 조회 실패, 내장 기본 프롬프트를 쓴다: {e!r}")

    _prompt_cache = (now, template, version)
    return template, version


def _validated_names(req: "AnalyzeRequest") -> tuple[str, list[str]]:
    """요청의 객체 이름이 이 세션에 서버가 발급한 형식인지 확인한다.

    다른 세션의 객체나 임의 경로를 모델에 넘기지 못하게 한다.
    """
    prefix = f"sessions/{req.session_id}/"

    def ok(name: str, pattern: re.Pattern) -> bool:
        return name.startswith(prefix) and bool(pattern.fullmatch(name[len(prefix):]))

    if not ok(req.audio_object, AUDIO_NAME):
        raise AnalysisFailed(400, "잘못된 객체 이름", "bad_request")
    if len(req.photo_objects) > MAX_PHOTOS or len(set(req.photo_objects)) != len(req.photo_objects):
        raise AnalysisFailed(400, "잘못된 객체 이름", "bad_request")
    if not all(ok(name, PHOTO_NAME) for name in req.photo_objects):
        raise AnalysisFailed(400, "잘못된 객체 이름", "bad_request")
    return req.audio_object, req.photo_objects


async def _call_vertex(contents: list, metrics: dict) -> types.GenerateContentResponse:
    deadline = time.monotonic() + VERTEX_DEADLINE_SECONDS
    for attempt in range(MAX_RETRIES + 1):
        remaining = deadline - time.monotonic()
        try:
            return await asyncio.wait_for(
                genai_client.aio.models.generate_content(
                    model=MODEL, contents=contents, config=GENERATION_CONFIG
                ),
                timeout=remaining,
            )
        except TimeoutError:
            raise AnalysisFailed(504, "Vertex AI 응답 시간 초과", "timeout")
        except genai_errors.APIError as e:
            if (
                e.code == 503
                and attempt < MAX_RETRIES
                and deadline - time.monotonic() > RETRY_DELAY_SECONDS
            ):
                metrics["retries"] += 1
                print(f"[vertex] 503 과부하, 재시도 {attempt + 1}/{MAX_RETRIES}")
                await asyncio.sleep(RETRY_DELAY_SECONDS)
                continue
            print(f"[vertex] 오류 code={e.code} status={e.status} message={e.message}")
            raise AnalysisFailed(502, f"Vertex AI 오류({e.code})", "model_error")
    raise AssertionError("unreachable")


def _normalize(parsed: object) -> dict:
    """스키마를 강제해도 앱 파싱이 깨지지 않도록 키·타입을 한 번 더 맞춘다."""
    if not isinstance(parsed, dict):
        raise AnalysisFailed(502, "Vertex AI 응답 형식 오류", "parse_error")
    result = {}
    for key, empty in EMPTY_RESULT.items():
        value = parsed.get(key, empty)
        if isinstance(empty, list):
            result[key] = [str(v) for v in value] if isinstance(value, list) else []
        else:
            result[key] = value if isinstance(value, str) else ""
    return result


def _delete_session_objects(session_id: str) -> tuple[bool, int]:
    """세션 폴더의 원본을 모두 지운다. (성공 여부, 지운 개수)를 돌려준다.

    요청에 적힌 이름만이 아니라 세션 접두사 전체를 지워, 앱이 올려 놓고
    분석 요청에 빠뜨린 파일까지 남기지 않는다. 그래도 놓친 파일은 버킷
    수명 주기 규칙(1일 경과 후 자동 파기)이 치운다.
    """
    deleted = 0
    ok = True
    try:
        for blob in bucket.list_blobs(prefix=f"sessions/{session_id}/"):
            try:
                blob.delete()
                deleted += 1
            except NotFound:
                pass
            except Exception as e:
                ok = False
                print(f"[analyze] 삭제 실패 {blob.name}: {e!r}")
    except Exception as e:
        ok = False
        print(f"[analyze] 삭제 대상 조회 실패: {e!r}")
    return ok, deleted


async def _record_metrics(session_id: str, metrics: dict) -> None:
    """비식별 메타데이터(소요시간·성공 여부·파일 크기)만 metrics/{세션ID}에 남긴다.

    환자 음성·사진·요약 내용은 넣지 않는다. 기록 실패가 대원에게 줄 결과를
    막으면 안 되므로 로그만 남긴다.
    """
    try:
        await firestore_client.collection("metrics").document(session_id).set(
            {**metrics, "created_at": firestore.SERVER_TIMESTAMP}, timeout=5
        )
    except Exception as e:
        print(f"[metrics] 기록 실패: {e!r}")


class AnalyzeRequest(BaseModel):
    session_id: str
    audio_object: str
    photo_objects: list[str] = []
    duration_seconds: int | None = None
    client_upload_ms: int | None = None


async def _analyze_session(req: AnalyzeRequest, metrics: dict) -> dict:
    audio_name, photo_names = _validated_names(req)

    if req.duration_seconds is None:
        raise AnalysisFailed(400, "duration_seconds가 필요합니다", "bad_request")
    metrics["duration_seconds"] = req.duration_seconds
    if req.duration_seconds < MIN_AUDIO_SECONDS:
        # 이미 올라간 원본은 호출한 쪽의 finally에서 지운다.
        print(f"[analyze] 녹음 {req.duration_seconds}초 — 너무 짧아 모델 호출 생략")
        metrics["skipped"] = "too_short"
        return dict(EMPTY_RESULT)

    blobs = await asyncio.to_thread(
        lambda: [bucket.get_blob(name) for name in [audio_name, *photo_names]]
    )
    audio_blob, photo_blobs = blobs[0], blobs[1:]
    if audio_blob is None:
        raise AnalysisFailed(400, "업로드된 오디오를 찾을 수 없음", "missing_object")
    if any(b is None for b in photo_blobs):
        raise AnalysisFailed(400, "업로드된 사진을 찾을 수 없음", "missing_object")
    # Content-Type은 서명에 묶여 있어 발급할 때 정한 값 그대로다. 그래도
    # 허용 목록 밖이면 모델에 넘기지 않는다.
    if audio_blob.content_type not in AUDIO_TYPES or any(
        b.content_type not in PHOTO_TYPES for b in photo_blobs
    ):
        raise AnalysisFailed(400, "허용하지 않는 파일 형식", "bad_request")
    metrics["audio_bytes"] = audio_blob.size
    metrics["photo_count"] = len(photo_blobs)
    metrics["photo_bytes_total"] = sum(b.size for b in photo_blobs)

    template, version = await _load_prompt()
    metrics["prompt_version"] = version
    now = datetime.now(KST).strftime("%H:%M")
    # 오디오·사진은 내려받지 않고 gs:// 주소만 넘긴다 — Vertex AI가 버킷에서 직접 읽는다.
    contents = [
        types.Part.from_text(text=template.replace("{now}", now)),
        types.Part.from_uri(
            file_uri=f"gs://{BUCKET}/{audio_name}", mime_type=audio_blob.content_type
        ),
        *(
            types.Part.from_uri(file_uri=f"gs://{BUCKET}/{b.name}", mime_type=b.content_type)
            for b in photo_blobs
        ),
    ]

    started = time.perf_counter()
    try:
        response = await _call_vertex(contents, metrics)
    finally:
        metrics["timings_ms"]["inference"] = round((time.perf_counter() - started) * 1000)

    # 오디오가 실제로 모델 입력에 잡혔는지 남긴다. AUDIO가 0이면 모델이 소리를
    # 못 듣고 프롬프트만 보고 답을 지어낸 것이므로, 결과를 믿어선 안 된다.
    usage = response.usage_metadata
    details = (usage.prompt_tokens_details if usage else None) or []
    audio_tokens = sum(
        d.token_count or 0 for d in details if d.modality == types.MediaModality.AUDIO
    )
    metrics["audio_tokens"] = audio_tokens
    modalities = {d.modality.value if d.modality else None: d.token_count for d in details}
    print(f"[analyze] usage={modalities}")
    if not audio_tokens:
        print("[analyze] 경고: 입력에 AUDIO 토큰이 없다 — 오디오가 모델에 닿지 않았다")

    candidate = response.candidates[0] if response.candidates else None
    finish_reason = candidate.finish_reason if candidate else None
    metrics["finish_reason"] = finish_reason.value if finish_reason else None
    if candidate is None:
        raise AnalysisFailed(502, "Vertex AI 응답이 비어 있음", "model_error")
    if finish_reason == types.FinishReason.MAX_TOKENS:
        raise AnalysisFailed(502, "Vertex AI 응답이 잘림(MAX_TOKENS)", "max_tokens")

    try:
        parsed = json.loads(response.text or "")
    except json.JSONDecodeError:
        # 응답 원문은 환자 정보이므로 로그에 남기지 않는다.
        raise AnalysisFailed(502, "Vertex AI 응답 JSON 파싱 실패", "parse_error")
    return _normalize(parsed)


@app.post("/api/analyze", dependencies=[Depends(require_app_token)])
async def analyze(req: AnalyzeRequest):
    """업로드된 오디오·사진의 gs:// 주소로 Vertex AI를 불러 구조화 결과를 돌려준다.

    분석이 성공하든 실패하든 finally에서 세션 원본을 지우고, 비식별 메타데이터를
    Firestore에 기록한다. 결과 내용은 로그·DB 어디에도 남기지 않는다.
    """
    if not SESSION_ID.fullmatch(req.session_id):
        raise HTTPException(400, "잘못된 세션 ID")

    started = time.perf_counter()
    metrics = {
        "success": False,
        "error_type": None,
        "skipped": None,
        "model": MODEL,
        "vertex_location": VERTEX_LOCATION,
        "prompt_version": None,
        "duration_seconds": None,
        "audio_bytes": None,
        "photo_count": None,
        "photo_bytes_total": None,
        "audio_tokens": None,
        "retries": 0,
        "finish_reason": None,
        "timings_ms": {"upload_client": req.client_upload_ms},  # 업로드는 앱이 잰 값
        "delete_ok": None,
    }
    try:
        result = await _analyze_session(req, metrics)
        metrics["success"] = True
        return result
    except AnalysisFailed as e:
        metrics["error_type"] = e.error_type
        raise HTTPException(e.status, e.detail)
    except Exception as e:
        metrics["error_type"] = "internal"
        print(f"[analyze] 예상치 못한 오류: {e!r}")
        raise HTTPException(500, "분석 중 서버 오류")
    finally:
        # 분석 성공·실패와 무관하게 환자 원본을 버킷에 남기지 않는다.
        delete_started = time.perf_counter()
        delete_ok, deleted = await asyncio.to_thread(_delete_session_objects, req.session_id)
        metrics["delete_ok"] = delete_ok
        metrics["timings_ms"]["delete"] = round((time.perf_counter() - delete_started) * 1000)
        metrics["timings_ms"]["server_total"] = round((time.perf_counter() - started) * 1000)
        print(
            f"[analyze] session={req.session_id} success={metrics['success']} "
            f"error={metrics['error_type']} deleted={deleted} timings={metrics['timings_ms']}"
        )
        # 단계별 소요시간은 발표 수치의 실측 근거가 된다.
        await _record_metrics(req.session_id, metrics)
