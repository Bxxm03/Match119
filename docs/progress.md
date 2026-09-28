# 진행 상황

## 백엔드 전환 (`feature/vertex-backend`)

PoC(Gemini Developer API 키 + Files API + multipart 업로드)를 CLAUDE.md 목표 아키텍처로 교체했다.

| 항목 | 상태 |
|---|---|
| `POST /api/uploads` — 서버가 세션 ID·객체 이름을 정하고 PUT Signed URL 발급(IAM signBlob) | 완료, 로컬에서 실제 버킷으로 확인 |
| Content-Type·용량 상한(오디오 50MB, 사진 10MB)을 서명에 묶음 | 완료, 형식 불일치 403 / 상한 초과 거부 확인 |
| `POST /api/analyze` — gs:// URI로 Vertex AI(`gemini-2.5-flash`, `asia-northeast3`) 호출 | 완료, 로컬에서 실호출 확인 |
| `finally`에서 세션 원본 삭제 | 완료, 정상·실패·짧은 녹음 모든 경로에서 삭제 확인 |
| Firestore `metrics/{세션ID}`에 비식별 메타데이터·단계별 소요시간 기록 | 완료, 로컬에서 기록 확인(테스트 문서는 삭제함) |
| Firestore `prompts/current` 프롬프트(캐시 TTL 1분 내 반영) | 코드 완료. **문서는 아직 안 올림** — 현재는 내장 기본 프롬프트(`version=builtin`)로 동작 |
| 공유 토큰 `X-RAPID-Token` — 무단 호출 방지용 최소 보호 | 완료 |
| 이어올리기(resumable) 업로드 | 미구현(예정). 현재는 단순 PUT |
| Cloud Run 배포 | 예정 |

남은 백엔드 작업:
- `python seed_prompt.py <버전>`으로 `prompts/current` 올리기
- Cloud Run 배포(CLAUDE.md 배포 명령, `APP_TOKEN` 값은 팀 내부로만 전달)
- 로컬 테스트 중 Vertex가 503이 아니라 **429 RESOURCE_EXHAUSTED**를 돌려준 적이 있다. 현재는 503만
  재시도한다 — 429도 재시도 대상에 넣을지 결정 필요.

## 앱 수정 필요 사항 (이번 백엔드 작업에서는 앱 코드를 고치지 않았다)

백엔드가 병합되면 구 multipart `/api/analyze`는 사라진다. **앱 수정과 병합 순서를 맞춰야** 앱이 깨지지 않는다.
작업 위치는 `lib/data/analysis_api.dart`(서버 통신은 이 파일에서만).

1. **분석 흐름을 3단계로 교체**
   1. 녹음 종료 후 **분석 직전에** `POST /api/uploads`로 Signed URL을 발급받는다.
      URL은 10분 뒤 만료되므로 녹음 시작 시점 등에 미리 받아 두지 않는다.
   2. 응답의 `audio`·`photos[]` 각각에 대해 `url`로 `PUT`. **응답의 `headers`를 그대로** 붙여야 한다
      (`Content-Type`, `x-goog-content-length-range` — 서명에 포함돼 있어 다르면 403/400).
   3. `POST /api/analyze`에 `session_id`, `audio_object`, `photo_objects`, `duration_seconds`,
      `client_upload_ms`(PUT에 걸린 시간, 선택)를 JSON으로 보낸다. 응답 8필드는 기존과 같아
      `AnalysisResult.fromJson`은 그대로 쓴다.
2. **`duration_seconds` 항상 전달** — 이제 필수값(없으면 400).
   - 태블릿 경로 `lib/platform/recording_service.dart`: 이미 전달 중.
   - PC 테스트 경로 `lib/platform/local_assistant_controller.dart`: `api.analyze(audio:, photos:)`만 불러
     누락 중 → 녹음 시간을 넘기도록 수정.
3. **2초 미만 녹음이면 업로드 자체를 생략**하고 빈 결과로 처리한다. 서버도 2초 미만이면 모델을 부르지 않고
   원본을 지우지만, 애초에 환자 음성을 올리지 않는 편이 낫다.
4. **공유 토큰 헤더** `X-RAPID-Token` — `/api/uploads`, `/api/analyze`에 붙인다. 값은
   `--dart-define=RAPID_TOKEN=...`으로 받는다. (`/api/health`는 토큰 불필요)
5. **MIME 지정** — 오디오는 현재 `.m4a`이므로 `audio_mime: "audio/mp4"`(`audio/wav`도 허용).
   사진은 실제 형식에 맞춰 `image/jpeg` 또는 `image/png`, 최대 3장.
6. **에러 문구 정리** — 백엔드 에러 코드가 바뀌었다. `_readableError`의 `GEMINI_API_KEY` 분기는 더 이상 쓸 일이 없다.

   | 코드 | 의미 |
   |---|---|
   | 400 | 요청 형식 오류, 객체 이름 불일치, 업로드된 파일 없음, `duration_seconds` 누락 |
   | 401 | 토큰 없음/불일치 |
   | 500 | 업로드 주소 발급 실패 등 서버 오류 |
   | 502 | Vertex AI 오류·응답 잘림·파싱 실패 |
   | 504 | Vertex AI 응답 시간 초과(`detail`에 "시간 초과" 포함 — 기존 판별 그대로 동작) |

### 요청/응답 예시

`POST /api/uploads`
```json
{ "audio_mime": "audio/mp4", "photo_mimes": ["image/jpeg", "image/png"] }
```
```json
{
  "session_id": "3f9c2a7e5b1d4c0e8a6f2b9d1e4c7a05",
  "expires_at": "2026-09-28T14:42:00+09:00",
  "audio": {
    "object": "sessions/3f9c2a7e5b1d4c0e8a6f2b9d1e4c7a05/audio.m4a",
    "url": "https://storage.googleapis.com/...",
    "method": "PUT",
    "headers": { "Content-Type": "audio/mp4", "x-goog-content-length-range": "0,52428800" }
  },
  "photos": [
    { "object": "sessions/3f9c.../photo-0.jpg", "url": "https://...", "method": "PUT",
      "headers": { "Content-Type": "image/jpeg", "x-goog-content-length-range": "0,10485760" } },
    { "object": "sessions/3f9c.../photo-1.png", "url": "https://...", "method": "PUT",
      "headers": { "Content-Type": "image/png", "x-goog-content-length-range": "0,10485760" } }
  ]
}
```

`POST /api/analyze`
```json
{
  "session_id": "3f9c2a7e5b1d4c0e8a6f2b9d1e4c7a05",
  "audio_object": "sessions/3f9c.../audio.m4a",
  "photo_objects": ["sessions/3f9c.../photo-0.jpg", "sessions/3f9c.../photo-1.png"],
  "duration_seconds": 47,
  "client_upload_ms": 1830
}
```
응답은 기존과 같은 8필드(`chief_complaint`, `past_history`, `onset`, `last_normal_time`, `guardian`,
`etc`, `ai_impression`, `reasons`).
