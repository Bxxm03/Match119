import asyncio
import hmac
import json
import os
import random
import re
import sys
import threading
import time
import uuid
from contextlib import asynccontextmanager
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
    SCHEMA_VERSION,
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
# 모델 thinking 토큰 한도. 기본 0(끔)이 운영값이고, 비교 실험할 때만 바꾼다.
try:
    THINKING_BUDGET = int(os.environ.get("THINKING_BUDGET", "").strip() or 0)
except ValueError:
    raise SystemExit("환경변수 THINKING_BUDGET은 정수여야 합니다")
if THINKING_BUDGET < 0:
    # -1(모델이 알아서 정함)은 한도를 알 수 없어 max_output_tokens를 다 쓸 수 있다.
    raise SystemExit("THINKING_BUDGET은 0 이상이어야 합니다")
# Gemini 3 계열은 thinking_budget 대신 thinking_level로 조절한다(둘을 같이 보내면 오류).
# gemini-3.5-flash는 thinking을 끌 수 없고, 0에 가장 가까운 값이 MINIMAL이다.
# 3.5-flash에 thinking_budget=0을 보내면 오디오 요청에서 간헐적으로 400
# ("Thinking budget is not supported for this model")이 났다(2026-10-01 자체 측정).
# 2.5 모델은 지금처럼 thinking_budget을 쓴다.
USE_THINKING_LEVEL = MODEL.startswith("gemini-3")
THINKING_LEVEL = "MINIMAL" if USE_THINKING_LEVEL else None
if USE_THINKING_LEVEL and os.environ.get("THINKING_BUDGET", "").strip():
    raise SystemExit("Gemini 3 계열에는 THINKING_BUDGET을 쓰지 않습니다(thinking_level=MINIMAL 고정)")
# 프롬프트 출처. 비우면 firestore(운영값)이고, builtin이면 Firestore를 읽지 않고
# 내장 기본 프롬프트만 쓴다 — 프롬프트 비교 실험할 때만 바꾼다.
PROMPT_SOURCE = os.environ.get("PROMPT_SOURCE", "").strip() or "firestore"
if PROMPT_SOURCE not in ("firestore", "builtin"):
    raise SystemExit("PROMPT_SOURCE는 firestore 또는 builtin이어야 합니다")
# Firestore prompts 컬렉션에서 읽을 문서 이름. 비우면 current(운영값)이고, 초안 문서를
# 시험할 때만 바꾼다. PROMPT_SOURCE=builtin이면 쓰이지 않는다.
PROMPT_DOC = os.environ.get("PROMPT_DOC", "").strip() or "current"
if "/" in PROMPT_DOC:
    raise SystemExit("PROMPT_DOC은 문서 이름만 적습니다(경로 구분자 / 불가)")

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
# 업로드 확인·프롬프트 조회·모델 호출(재시도 포함)을 모두 이 한 예산 안에서 처리하고,
# 모델에는 앞 단계가 쓰고 남은 시간만 준다.
REQUEST_DEADLINE_SECONDS = 75
# 예산 안에서 부르는 GCS·Firestore 호출 한 번의 한도(남은 예산이 더 적으면 그만큼만).
STORAGE_TIMEOUT_SECONDS = 5
FIRESTORE_TIMEOUT_SECONDS = 5
# 정리 단계(원본 삭제·메타데이터 기록)는 예산이 바닥나도 반드시 시도하므로 예산 밖에서
# 따로 한도를 둔다. 최악: 75 + 목록 4 + 삭제 4(병렬) + 기록 3 = 86초 < 앱 90초.
CLEANUP_TIMEOUT_SECONDS = 4
METRICS_TIMEOUT_SECONDS = 3
# 503(과부하)와 429(할당량 초과)는 흔히 발생 — 남은 예산 안에서만 최대 2회 재시도.
# 서울 리전 테스트에서 503보다 429가 더 자주 나왔다.
RETRYABLE_CODES = (429, 503)
MAX_RETRIES = 2
# 대기 시간: 1초, 2초 … 로 두 배씩 늘리고, 여러 요청이 동시에 다시 몰리지 않게
# 0~1초 지터를 더한다.
RETRY_BASE_DELAY_SECONDS = 1.0

# 프롬프트 수정은 캐시 TTL(1분) 내 반영된다.
PROMPT_CACHE_SECONDS = 60
# Firestore 조회가 실패해 기본 프롬프트로 대신했을 때는 짧게만 캐시해, 복구되면
# 곧 Firestore 프롬프트로 돌아가게 한다.
PROMPT_FALLBACK_CACHE_SECONDS = 10

GENERATION_CONFIG = types.GenerateContentConfig(
    # 온도를 낮춰서 대화에 없는 내용을 그럴듯하게 채워 넣는 것(hallucination)을
    # 최대한 억제한다 — 이 작업은 창의성이 아니라 정확한 인용이 목적이다.
    temperature=0,
    # 대화 듣고 정해진 스키마 채우는 작업이라 추론이 필요 없다. thinking을 켜 두면
    # max_output_tokens가 thinking에 먼저 소모되어 MAX_TOKENS로 빈 응답이 나올 수 있다.
    thinking_config=(types.ThinkingConfig(thinking_level=THINKING_LEVEL) if USE_THINKING_LEVEL
                     else types.ThinkingConfig(thinking_budget=THINKING_BUDGET)),
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

@asynccontextmanager
async def lifespan(_app: FastAPI):
    # 첫 요청이 Firestore 연결·조회 시간(실측 1초 이상)을 떠안지 않게 기동 시 미리 읽어 둔다.
    # 실패해도 기동은 계속하고(기본 프롬프트 10초 캐시), 이후 요청에서 다시 읽는다.
    try:
        _, version = await _load_prompt(time.monotonic() + FIRESTORE_TIMEOUT_SECONDS)
        print(f"[prompt] 기동 시 프롬프트 캐시 완료 (version={version})")
    except Exception as e:
        print(f"[prompt] 경고: 기동 시 프롬프트 조회 실패: {e!r}")
    yield


app = FastAPI(lifespan=lifespan)


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


def _remaining(deadline: float, error_detail: str) -> float:
    """남은 예산(초). 이미 바닥났으면 시간 초과로 끝낸다."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise AnalysisFailed(504, error_detail, "timeout")
    return remaining


# (캐시 만료 시각, 템플릿, 버전)
_prompt_cache: tuple[float, str, str] | None = None


async def _load_prompt(deadline: float) -> tuple[str, str]:
    """Firestore prompts/{PROMPT_DOC}(기본 current)에서 (템플릿, 버전)을 읽는다. 1분간 캐시한다.

    Firestore를 못 읽어도 분석 자체가 멈추면 안 되므로 내장 기본 프롬프트로
    대신하고 버전을 "builtin"으로 남긴다. 이때는 10초만 캐시한다.
    """
    global _prompt_cache
    if PROMPT_SOURCE == "builtin":
        return DEFAULT_PROMPT_TEMPLATE, DEFAULT_PROMPT_VERSION
    now = time.monotonic()
    if _prompt_cache and now < _prompt_cache[0]:
        return _prompt_cache[1], _prompt_cache[2]

    timeout = min(FIRESTORE_TIMEOUT_SECONDS, _remaining(deadline, "서버 처리 시간 초과"))
    template, version = DEFAULT_PROMPT_TEMPLATE, DEFAULT_PROMPT_VERSION
    ttl = PROMPT_CACHE_SECONDS
    try:
        # 라이브러리 자동 재시도는 끄고, 한도를 넘기면 기본 프롬프트로 넘어간다.
        snap = await asyncio.wait_for(
            firestore_client.collection("prompts").document(PROMPT_DOC).get(
                timeout=timeout, retry=None
            ),
            timeout=timeout,
        )
        data = snap.to_dict() if snap.exists else None
        if data and data.get("template"):
            template = data["template"]
            version = str(data.get("version", "unknown"))
        else:
            print(f"[prompt] 경고: prompts/{PROMPT_DOC} 문서가 없어 내장 기본 프롬프트를 쓴다")
    except Exception as e:
        ttl = PROMPT_FALLBACK_CACHE_SECONDS
        print(f"[prompt] 경고: Firestore 조회 실패, 내장 기본 프롬프트를 {ttl}초간 쓴다: {e!r}")

    if "{now}" not in template:
        # {now}가 없으면 모델이 "20분 전" 같은 상대시간을 절대시각으로 바꿀 기준이 없다.
        print(f"[prompt] 경고: 프롬프트(version={version})에 {{now}}가 없어 현재 시각이 들어가지 않는다")

    _prompt_cache = (now + ttl, template, version)
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


async def _call_vertex(
    contents: list, metrics: dict, deadline: float
) -> types.GenerateContentResponse:
    """요청 예산에서 앞 단계가 쓰고 남은 시간 안에서만 모델을 부른다."""
    for attempt in range(MAX_RETRIES + 1):
        remaining = _remaining(deadline, "Vertex AI 응답 시간 초과")
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
            delay = RETRY_BASE_DELAY_SECONDS * 2**attempt + random.uniform(0, RETRY_BASE_DELAY_SECONDS)
            # 기다린 뒤에도 예산이 남아 있을 때만 다시 부른다.
            if (
                e.code in RETRYABLE_CODES
                and attempt < MAX_RETRIES
                and deadline - time.monotonic() > delay
            ):
                metrics["retries"] += 1
                metrics["retries_by_code"][str(e.code)] += 1
                print(
                    f"[vertex] {e.code} {e.status}, {delay:.1f}초 후 재시도 "
                    f"{attempt + 1}/{MAX_RETRIES}"
                )
                await asyncio.sleep(delay)
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


def _delete_blob(blob: storage.Blob) -> None:
    try:
        blob.delete(timeout=CLEANUP_TIMEOUT_SECONDS)
    except NotFound:
        pass


async def _delete_session_objects(session_id: str) -> tuple[bool, int]:
    """세션 폴더의 원본을 모두 지운다. (성공 여부, 지운 개수)를 돌려준다.

    요청 예산과 무관하게 항상 시도한다. 요청에 적힌 이름만이 아니라 세션 접두사
    전체를 지워, 앱이 올려 놓고 분석 요청에 빠뜨린 파일까지 남기지 않는다.
    한도 안에 못 끝낸 삭제는 스레드에서 계속 진행되고, 그래도 놓친 파일은 버킷
    수명 주기 규칙(1일 경과 후 자동 파기)이 치운다.
    """
    try:
        blobs = await asyncio.wait_for(
            asyncio.to_thread(
                lambda: list(
                    bucket.list_blobs(
                        prefix=f"sessions/{session_id}/", timeout=CLEANUP_TIMEOUT_SECONDS
                    )
                )
            ),
            timeout=CLEANUP_TIMEOUT_SECONDS,
        )
    except Exception as e:
        print(f"[analyze] 삭제 대상 조회 실패: {e!r}")
        return False, 0

    # 파일마다 기다리면 한도가 개수만큼 늘어나므로 병렬로 지운다.
    results = await asyncio.gather(
        *(
            asyncio.wait_for(asyncio.to_thread(_delete_blob, b), timeout=CLEANUP_TIMEOUT_SECONDS)
            for b in blobs
        ),
        return_exceptions=True,
    )
    ok = True
    for blob, result in zip(blobs, results):
        if isinstance(result, BaseException):
            ok = False
            print(f"[analyze] 삭제 실패 {blob.name}: {result!r}")
    return ok, sum(1 for r in results if not isinstance(r, BaseException))


async def _record_metrics(session_id: str, metrics: dict) -> None:
    """비식별 메타데이터(소요시간·성공 여부·파일 크기)만 metrics/{세션ID}에 남긴다.

    환자 음성·사진·요약 내용은 넣지 않는다. 기록 실패가 대원에게 줄 결과를
    막으면 안 되므로 로그만 남긴다.
    """
    try:
        await asyncio.wait_for(
            firestore_client.collection("metrics").document(session_id).set(
                {**metrics, "created_at": firestore.SERVER_TIMESTAMP},
                timeout=METRICS_TIMEOUT_SECONDS,
                retry=None,
            ),
            timeout=METRICS_TIMEOUT_SECONDS,
        )
    except Exception as e:
        print(f"[metrics] 기록 실패: {e!r}")


class AnalyzeRequest(BaseModel):
    session_id: str
    audio_object: str
    photo_objects: list[str] = []
    duration_seconds: int | None = None
    client_upload_ms: int | None = None


def _get_blob(name: str) -> storage.Blob | None:
    # 자동 재시도는 끈다 — 재시도가 예산을 넘겨 쓰지 않게 한다.
    return bucket.get_blob(name, timeout=STORAGE_TIMEOUT_SECONDS, retry=None)


async def _analyze_session(req: AnalyzeRequest, metrics: dict, deadline: float) -> dict:
    audio_name, photo_names = _validated_names(req)

    if req.duration_seconds is None:
        raise AnalysisFailed(400, "duration_seconds가 필요합니다", "bad_request")
    metrics["duration_seconds"] = req.duration_seconds
    if req.duration_seconds < MIN_AUDIO_SECONDS:
        # 이미 올라간 원본은 호출한 쪽의 finally에서 지운다.
        print(f"[analyze] 녹음 {req.duration_seconds}초 — 너무 짧아 모델 호출 생략")
        metrics["skipped"] = "too_short"
        return dict(EMPTY_RESULT)

    timeout = min(STORAGE_TIMEOUT_SECONDS, _remaining(deadline, "서버 처리 시간 초과"))
    try:
        blobs = await asyncio.wait_for(
            asyncio.gather(
                *(asyncio.to_thread(_get_blob, name) for name in [audio_name, *photo_names])
            ),
            timeout=timeout,
        )
    except TimeoutError:
        raise AnalysisFailed(504, "서버 처리 시간 초과(업로드 확인)", "timeout")
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

    template, version = await _load_prompt(deadline)
    metrics["prompt_version"] = version
    metrics["prompt_missing_now"] = "{now}" not in template
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
        response = await _call_vertex(contents, metrics, deadline)
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
    metrics["thoughts_tokens"] = (usage.thoughts_token_count if usage else None) or 0
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
    # 업로드 확인·프롬프트 조회·모델 호출이 함께 쓰는 요청 예산. 정리 단계는 예산 밖.
    deadline = time.monotonic() + REQUEST_DEADLINE_SECONDS
    metrics = {
        "success": False,
        "error_type": None,
        "skipped": None,
        "model": MODEL,
        "vertex_location": VERTEX_LOCATION,
        # 실제로 보낸 thinking 설정 — 둘 중 하나만 값이 있다(Gemini 3 계열은 level).
        "thinking_budget": None if USE_THINKING_LEVEL else THINKING_BUDGET,
        "thinking_level": THINKING_LEVEL,
        "thoughts_tokens": None,  # 모델이 실제로 thinking에 쓴 토큰
        "prompt_version": None,
        "schema_version": SCHEMA_VERSION,  # 코드가 소유한 칸 설명의 버전
        "prompt_missing_now": None,  # 프롬프트에 {now}가 없어 현재 시각이 안 들어갔으면 True
        "duration_seconds": None,
        "audio_bytes": None,
        "photo_count": None,
        "photo_bytes_total": None,
        "audio_tokens": None,
        "retries": 0,
        "retries_by_code": {str(code): 0 for code in RETRYABLE_CODES},  # {"429": n, "503": n}
        "finish_reason": None,
        "timings_ms": {"upload_client": req.client_upload_ms},  # 업로드는 앱이 잰 값
        "delete_ok": None,
    }
    try:
        result = await _analyze_session(req, metrics, deadline)
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
        # 분석 성공·실패, 예산 소진 여부와 무관하게 환자 원본 삭제를 반드시 시도한다.
        delete_started = time.perf_counter()
        delete_ok, deleted = await _delete_session_objects(req.session_id)
        metrics["delete_ok"] = delete_ok
        metrics["timings_ms"]["delete"] = round((time.perf_counter() - delete_started) * 1000)
        metrics["timings_ms"]["server_total"] = round((time.perf_counter() - started) * 1000)
        print(
            f"[analyze] session={req.session_id} success={metrics['success']} "
            f"error={metrics['error_type']} deleted={deleted} timings={metrics['timings_ms']}"
        )
        # 단계별 소요시간은 발표 수치의 실측 근거가 된다.
        await _record_metrics(req.session_id, metrics)
