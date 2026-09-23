import asyncio
import base64
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

# Windows 콘솔 기본 인코딩(cp949)이 한글 로그의 em-dash 등을 못 받아써서
# 요청 처리 중 서버가 죽었다. 프린트문마다 고치는 대신 stdout 자체를 UTF-8로
# 고정해 이 클래스의 크래시를 통째로 없앤다.
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse

# 파일럿 웹 페이지. /api/analyze를 상대경로로 부르길래 같은 서버에서
# 같이 서빙해 별도 서버·터널 없이 지금 백엔드 터널 그대로 쓴다.
PILOT_WEB_INDEX = Path(r"C:\Users\82105\Desktop\학교\구글캡스톤\web\index.html")

# 이보다 짧은 녹음은 Gemini를 부르지 않는다 — 대화라 부를 만한 게 담기기엔
# 너무 짧아서, 모델이 애매한 잡음을 그럴듯한 응급상황으로 지어내는 원인이었다.
MIN_AUDIO_SECONDS = 2

load_dotenv(Path(__file__).parent / ".env")

GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")
# 별칭을 기본값으로 둔다. 특정 버전을 박아 두면 그 모델이 내려갈 때 404로 죽는다
# (파일럿에서 gemini-2.5-flash가 그렇게 죽었다).
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-flash-latest")
GEMINI_URL = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent"

app = FastAPI()


@app.get("/")
async def pilot_web():
    return FileResponse(PILOT_WEB_INDEX)


@app.get("/api/health")
async def health():
    """앱이 백엔드를 찾았는지 확인하는 용도. 키 값은 노출하지 않는다."""
    return {"ok": True, "model": GEMINI_MODEL, "key_configured": bool(GEMINI_API_KEY)}

# 대화 원문 표현 + 의학용어 병기(기본 필드) / ai_impression은 질환군명 수준까지만 / reasons는 평이한 관찰언어
# — EMS_기획안_v2.md 03번 섹션 스키마·원칙 그대로.
#
# onset/last_normal_time은 "20분 전"처럼 상대시간으로 말하는 게 보통이라, 대원이
# 그걸 다시 시계로 환산하는 수고를 없애려고 서버 현재 시각을 프롬프트에 박아
# 넣고 모델이 직접 절대시각으로 계산하게 한다(요청 시점마다 새로 만들어야
# 해서 함수로 뺐다 — 모듈 로드 시 한 번만 박히는 상수면 안 된다).
def build_schema_prompt() -> str:
    now = datetime.now().strftime("%H:%M")
    return f"""다음 오디오는 구급대원과 환자(또는 보호자) 간 실제 대화 녹음이다. 사진이 함께 제공되면 시각적 소견도 참고하라.
현재 서버 시각은 {now}이다.
아래 JSON 스키마 형식으로만 응답하라 (설명 문장, 코드블록 없이 JSON 객체만):

{{
  "chief_complaint": "주증상 — 대화 원문 표현에 의학용어를 괄호로 병기",
  "past_history": "과거력(다니는 병원 포함)",
  "onset": "발병시점 — 대화에 '20분 전'처럼 상대시간으로 나오면 '원래 표현(계산된 절대시각 HH:MM)' 형식으로 적어라(예: 현재 14:52, '20분 전' → '20분전(14:32)'). 처음부터 시각으로 말했으면 그 시각만 적어라.",
  "last_normal_time": "마지막 정상확인시간 — onset과 같은 표기 방식(원래 표현+절대시각). onset과 별개로 대화에서 명시적으로 언급된 경우에만 채워라 — 대화에 따로 나온 게 없으면 onset과 같은 값을 넣지 말고 빈 문자열로 남겨라.",
  "guardian": "보호자 동승 여부",
  "etc": "기타 특이사항 — 외상이면 다친 경위(어디서/어떻게 다쳤는지)를 포함",
  "ai_impression": "의심 소견 — 대원이 현장에서 쓰는 질환군명 수준까지만, 세부 임상분류 제외. 확정 진단 아님",
  "reasons": ["근거1 — 평이한 관찰언어로만, 의학용어·진단명 쓰지 않음", "근거2"]
}}

각 필드는 대화에서 그 내용이 직접 언급된 경우에만 채워라. 필드별로 독립적으로
판단하라 — 예를 들어 주증상은 나왔지만 발병시점은 안 나왔으면, 주증상만 채우고
발병시점은 빈 문자열로 남겨라. 다른 필드에 내용이 있다고 해서, 또는 그럴듯해
보인다고 해서 언급되지 않은 필드를 추측해서 채우지 마라.
오디오가 너무 짧거나, 잡음뿐이거나, 실제 대화 내용을 알아들을 수 없으면
절대로 그럴듯한 상황을 지어내지 마라 — 그런 경우 모든 필드를 빈 문자열(reasons는
빈 배열)로 남겨라."""

EMPTY_RESULT = {
    "chief_complaint": "",
    "past_history": "",
    "onset": "",
    "last_normal_time": "",
    "guardian": "",
    "etc": "",
    "ai_impression": "",
    "reasons": [],
}


def _audio_mime(filename: str | None, content_type: str | None) -> str:
    """Gemini가 디코딩할 수 있는 오디오 MIME을 고른다.

    Flutter의 MultipartFile은 content-type을 지정하지 않으면
    application/octet-stream을 보낸다. 그대로 넘기면 Gemini가 무엇인지 몰라
    처리하지 못하므로, 확장자로 실제 타입을 정한다.
    """
    if content_type and content_type.startswith("audio/"):
        return content_type

    ext = Path(filename or "").suffix.lower()
    return {
        ".m4a": "audio/mp4",
        ".mp4": "audio/mp4",
        ".aac": "audio/aac",
        ".wav": "audio/wav",
        ".mp3": "audio/mpeg",
        ".ogg": "audio/ogg",
        ".opus": "audio/ogg",
        ".webm": "audio/webm",
        ".flac": "audio/flac",
    }.get(ext, "audio/mp4")


async def upload_file(
    client: httpx.AsyncClient, data: bytes, mime: str, display_name: str
) -> str:
    """Files API에 올리고 참조용 URI를 돌려준다."""
    start = await client.post(
        f"https://generativelanguage.googleapis.com/upload/v1beta/files?key={GEMINI_API_KEY}",
        headers={
            "X-Goog-Upload-Protocol": "resumable",
            "X-Goog-Upload-Command": "start",
            "X-Goog-Upload-Header-Content-Length": str(len(data)),
            "X-Goog-Upload-Header-Content-Type": mime,
            "Content-Type": "application/json",
        },
        json={"file": {"display_name": display_name}},
    )
    if start.status_code != 200:
        raise HTTPException(400, f"파일 업로드 시작 실패({start.status_code}): {start.text}")

    upload_url = start.headers.get("x-goog-upload-url")
    if not upload_url:
        raise HTTPException(400, "파일 업로드 URL을 받지 못했습니다")

    done = await client.post(
        upload_url,
        headers={
            "Content-Length": str(len(data)),
            "X-Goog-Upload-Offset": "0",
            "X-Goog-Upload-Command": "upload, finalize",
        },
        content=data,
    )
    if done.status_code != 200:
        raise HTTPException(400, f"파일 업로드 실패({done.status_code}): {done.text}")

    uri = done.json().get("file", {}).get("uri")
    if not uri:
        raise HTTPException(400, "업로드된 파일 URI를 받지 못했습니다")
    print(f"[analyze] uploaded -> {uri}")
    return uri


async def delete_uploaded_file(client: httpx.AsyncClient, file_uri: str) -> None:
    """분석이 끝나면 Files API에 올려둔 사본을 지운다.

    Gemini 유료 티어는 프롬프트·응답을 학습에 안 쓰지만(Zero Data Retention),
    Files API로 올린 파일은 예외다 — 사용자가 직접 지워야 완전한 ZDR이 된다
    (https://ai.google.dev/gemini-api/docs/zdr). 지우지 않으면 환자 음성이
    구글 쪽에 기본 48시간 남는다. 분석 성공·실패와 무관하게 항상 호출한다.
    """
    name = file_uri.rsplit("/files/", 1)[-1]
    try:
        res = await client.delete(
            f"https://generativelanguage.googleapis.com/v1beta/files/{name}",
            params={"key": GEMINI_API_KEY},
        )
        if res.status_code == 200:
            print(f"[analyze] 파일 삭제됨 -> {file_uri}")
        else:
            print(f"[analyze] 파일 삭제 실패({res.status_code}): {res.text}")
    except httpx.HTTPError as e:
        # 삭제 실패로 분석 자체를 실패시키지는 않는다 — 이미 대원에게 결과를
        # 주는 게 우선이다. 대신 로그에 남겨 놓쳤을 때 추적할 수 있게 한다.
        print(f"[analyze] 파일 삭제 중 오류: {e}")


def strip_code_fence(text: str) -> str:
    match = re.search(r"\{.*\}", text, re.DOTALL)
    return match.group(0) if match else text


@app.post("/api/analyze")
async def analyze(
    audio: UploadFile = File(...),
    photo: list[UploadFile] = File(default=[]),
    duration_seconds: int = Form(0),
):
    if not GEMINI_API_KEY:
        raise HTTPException(500, "backend/.env 에 GEMINI_API_KEY가 없음")

    if duration_seconds and duration_seconds < MIN_AUDIO_SECONDS:
        print(f"[analyze] 녹음 {duration_seconds}초 — 너무 짧아 Gemini 호출 생략")
        return EMPTY_RESULT

    parts = [{"text": build_schema_prompt()}]

    audio_bytes = await audio.read()
    audio_mime = _audio_mime(audio.filename, audio.content_type)
    print(f"[analyze] audio={audio.filename} mime={audio_mime} bytes={len(audio_bytes)}")

    # 오디오는 Files API로 올린 뒤 URI로 참조한다.
    # inline_data로 넣으면 최신 flash 계열이 오디오를 조용히 버리고
    # (응답 usage의 promptTokensDetails에 AUDIO가 아예 안 잡힌다) 프롬프트만 보고
    # 그럴듯한 케이스를 지어낸다 — 환자 정보가 통째로 발명되는 셈이라 위험하다.
    async with httpx.AsyncClient(timeout=75.0) as upload_client:
        audio_uri = await upload_file(
            upload_client, audio_bytes, audio_mime, audio.filename or "audio"
        )
    parts.append({"file_data": {"mime_type": audio_mime, "file_uri": audio_uri}})

    # 사진은 작아서 inline으로 충분하다(이미지는 정상 처리됨).
    for p in photo[:3]:
        photo_bytes = await p.read()
        parts.append({
            "inline_data": {
                "mime_type": p.content_type or "image/jpeg",
                "data": base64.b64encode(photo_bytes).decode(),
            }
        })

    try:
        # 최신 flash 계열은 응답 전에 추론을 하므로 30초로는 긴 대화가 잘린다.
        # 앱 쪽 타임아웃(90초)보다 짧게 두어, 서버가 먼저 이유 있는 에러를 만들게 한다.
        async with httpx.AsyncClient(timeout=75.0) as client:
            for attempt in range(3):  # Gemini 503(과부하)는 흔히 발생 — 최대 2회 재시도
                try:
                    res = await client.post(
                        GEMINI_URL,
                        params={"key": GEMINI_API_KEY},
                        json={
                            "contents": [{"parts": parts}],
                            # 대화 듣고 정해진 스키마 채우는 작업이라 추론이 필요 없다.
                            # thinking을 켜 두면 매 호출마다 그 오버헤드가 그대로
                            # 응답 지연으로 붙는다 — 현장에서는 속도가 더 중요하다.
                            "generationConfig": {
                                "thinkingConfig": {"thinkingBudget": 0},
                                # 온도를 낮춰서 대화에 없는 내용을 그럴듯하게
                                # 채워 넣는 것(hallucination)을 최대한 억제한다 —
                                # 이 작업은 창의성이 아니라 정확한 인용이 목적이다.
                                "temperature": 0,
                            },
                        },
                    )
                except httpx.TimeoutException:
                    # 502/504는 Cloudflare 터널이 자체 에러 페이지로 덮어써서 클라이언트에 원인이 안 보임 — 400 사용
                    raise HTTPException(400, "Gemini 응답 시간 초과")

                if res.status_code == 503 and attempt < 2:
                    print(f"[gemini] 503 과부하, 재시도 {attempt + 1}/2")
                    await asyncio.sleep(1.5)
                    continue
                break
    finally:
        # 분석이 성공하든 실패하든 환자 음성 사본은 구글 쪽에 남겨두지 않는다.
        async with httpx.AsyncClient(timeout=15.0) as del_client:
            await delete_uploaded_file(del_client, audio_uri)

    if res.status_code != 200:
        print(f"[gemini] status={res.status_code} body={res.text}")
        raise HTTPException(400, f"Gemini API 오류({res.status_code}): {res.text}")

    body = res.json()

    # 오디오가 실제로 모델 입력에 잡혔는지 남긴다. AUDIO가 0이면 모델이 소리를
    # 못 듣고 프롬프트만 보고 답을 지어낸 것이므로, 결과를 믿어선 안 된다.
    usage = body.get("usageMetadata", {})
    modalities = {
        d.get("modality"): d.get("tokenCount")
        for d in usage.get("promptTokensDetails", [])
    }
    print(f"[analyze] usage={modalities} thoughts={usage.get('thoughtsTokenCount')}")
    if not modalities.get("AUDIO"):
        print("[analyze] 경고: 입력에 AUDIO 토큰이 없다 — 오디오가 모델에 닿지 않았다")

    # 최신 모델은 parts에 thought 블록을 먼저 넣기도 해서, 첫 part만 보면
    # text가 비어 있을 수 있다. text가 있는 part를 찾아 이어붙인다.
    parts = body.get("candidates", [{}])[0].get("content", {}).get("parts", [])
    text = "".join(p.get("text", "") for p in parts if isinstance(p, dict))
    try:
        result = json.loads(strip_code_fence(text))
    except json.JSONDecodeError:
        raise HTTPException(400, f"Gemini 응답 JSON 파싱 실패: {text}")

    # 진단용 — 어떤 필드가 왜 잘못 채워지는지 실제 결과를 봐야 알 수 있다.
    # 원인 확인되면 지운다.
    print(f"[analyze] result={json.dumps(result, ensure_ascii=False)}")

    return result
