# 진행 상황

## 백엔드 전환 (`feature/vertex-backend`)

PoC(Gemini Developer API 키 + Files API + multipart 업로드)를 CLAUDE.md 목표 아키텍처로 교체했다.

| 항목 | 상태 |
|---|---|
| `POST /api/uploads` — 서버가 세션 ID·객체 이름을 정하고 PUT Signed URL 발급(IAM signBlob) | 완료, 로컬에서 실제 버킷으로 확인 |
| Content-Type·용량 상한(오디오 50MB, 사진 10MB)을 서명에 묶음 | 완료, 형식 불일치 403 / 상한 초과 거부 확인 |
| `POST /api/analyze` — gs:// URI로 Vertex AI(`gemini-2.5-flash`, 도쿄 `asia-northeast1`) 호출 | 완료, 로컬에서 실호출 확인. 2026-09-28 서울 → 도쿄 전환(아래 "AI 추론 리전 전환") |
| `finally`에서 세션 원본 삭제 | 완료, 정상·실패·짧은 녹음 모든 경로에서 삭제 확인 |
| Firestore `metrics/{세션ID}`에 비식별 메타데이터·단계별 소요시간 기록 | 완료, 로컬에서 기록 확인(테스트 문서는 삭제함) |
| Firestore `prompts/current` 프롬프트(캐시 TTL 1분 내 반영) | 완료. 2026-09-28에 `version=2026-09-28a`(내장 기본 프롬프트와 같은 내용) 업로드, 로컬 서버가 기동 시 이 버전을 읽는 것 확인 |
| 공유 토큰 `X-RAPID-Token` — 무단 호출 방지용 최소 보호 | 완료 |
| 요청 전체 75초 예산(업로드 확인·프롬프트 조회·모델 호출), 정리 단계는 예산 밖 짧은 한도 — 최악 86초 < 앱 90초 | 완료, 로컬에서 예산 소진·지연 상황 확인 |
| Vertex 429·503 재시도(최대 2회, 지수 대기 + 지터, 남은 예산 안에서만), metrics에 코드별 횟수 | 완료, 가짜 응답으로 동작 확인 |
| 기동 시 프롬프트 미리 캐시, 조회 실패 시 기본 프롬프트 10초 캐시 | 완료 |
| 이어올리기(resumable) 업로드 | 미구현(예정). 현재는 단순 PUT |
| Cloud Run 배포 | 예정 |

남은 백엔드 작업:
- Cloud Run 배포(CLAUDE.md 배포 명령, `APP_TOKEN` 값은 팀 내부로만 전달)

## AI 추론 리전 전환: 서울 → 도쿄 (2026-09-28 결정)

**결정:** Vertex AI 호출을 `asia-northeast3`(서울) → **`asia-northeast1`(도쿄)**, 모델은 `gemini-2.5-flash` 유지.
버킷·Firestore·Cloud Run은 서울 그대로. 발표 문구: "원본 파일 보관·삭제는 서울 리전, AI 추론은 도쿄 리전".
코드 변경 없이 환경변수(`VERTEX_LOCATION`)만 바꿨다.

### 서울 429 관찰 (자체 측정)

- 서울 `gemini-2.5-flash`로 스모크 테스트를 16:40~17:03에 5분 이상 간격으로 4회 → **4회 모두 실패, HTTP 호출 12번 모두 429 RESOURCE_EXHAUSTED.**
  그보다 앞선 스모크 테스트 2회도 같은 양상으로 실패.
- google-genai는 자체 재시도를 하지 않는다(`retry_options` 미설정 → 1회 시도, 실측으로도 호출당 HTTP 1번 확인).
  **429 하나가 돌아오는 데 Vertex 쪽에서 6.4~8.8초**가 걸려, 재시도 2회를 합쳐 요청마다 24~29초 뒤 502.
- 콘솔 할당량 화면의 서울 사용률 **0.05%** → 우리 할당량이 아니라 리전 공유 용량 부족(조정 불가 시스템 한도)으로 판단.

### 도쿄 A/B 시험 (같은 녹음 `Scenario.m4a` 74초, 모델당 2회, 3분 간격)

| | 성공 / 429 | 분석 요청 평균(앱 기준) | 추론 평균(서버) | 1회차 / 2회차 추론 |
|---|---|---|---|---|
| **A** 도쿄 `gemini-2.5-flash` | 2 / 0 | 6.5초 | 5.7초 | 6.6초 / 4.8초 |
| **B** 도쿄 `gemini-3.5-flash` | 2 / 0 | 8.3초 | 7.5초 | 6.5초 / 8.6초 |

- 두 모델 모두 `thinking_budget 0` 정상(thinking 토큰 없음, `finish_reason=STOP`), `response_schema` 8칸·타입 준수,
  AUDIO 토큰 정상(A 1,875 / B 1,858).
- 모델당 2회라 소요시간 차이는 참고 수준.

### 채점 (정답 기준: 실제 대화 텍스트, 성공 4건 × 8칸)

| | ✅ 맞음 | ⚠️ 부분 | ❌ 틀림 | ➖ 빠짐 | 🚫 지어냄(칸) | 칸 안에 대화에 없는 내용 |
|---|---|---|---|---|---|---|
| **A** 2.5-flash | 7 | 9 | 0 | 0 | 0 | 0 |
| **B** 3.5-flash | 6 | 8 | 2 | 0 | 0 | 2 |

- A: onset(40분 전 시작 → 20분 전 악화)을 2회 모두 담음. 약점은 ai_impression이 증상명("흉통")에 머묾,
  chief_complaint 원문 표현 형식이 2회 중 1회만 지켜짐, 1회차에 가족력(아버지 심근경색) 누락.
- B: ai_impression은 질환군("심혈관계 질환")으로 적절. 그러나 guardian에 **"동승 예정(부모)", "동승 예정(아버지)"** —
  대화는 "아버지가 오신다"뿐이라 어머니·동승은 지어낸 내용. onset 악화 시점 2회 모두 누락, reasons에 "방사통" 같은 의학용어.
- 공통: last_normal_time은 모두 빈칸으로 정확, onset 절대시각은 실행 시각 기준으로 정확, "진단/확정" 같은 단정 표현 없음.
- **지어낸 내용이 없는 A를 선택.** A의 ai_impression·chief_complaint 약점은 Firestore 프롬프트 보강으로 나아질 여지가 있다(진행 여부 미정).

### 남은 일

- `gemini-2.5-flash`는 **2026-10-20 종료**. 10/7 이후에도 쓰려면 그 전에 도쿄 `gemini-3.5-flash`로 전환하되,
  보호자 칸 지어냄을 막도록 프롬프트를 보강한 뒤 같은 방식으로 다시 채점한다.

### 배포 후 확인 필요

- **응답 후에도 계속되는 원본 삭제가 Cloud Run에서 끝까지 도는지.** 삭제는 예산이 바닥나도 반드시 시도하지만,
  응답을 늦추지 않도록 4초 한도 안에 못 끝낸 삭제는 응답을 보낸 뒤 스레드에서 이어서 진행된다.
  Cloud Run 기본 설정(요청 기반 CPU 할당)에서는 응답을 보낸 뒤 CPU가 거의 할당되지 않아 이 삭제가
  멈추거나 인스턴스와 함께 사라질 수 있다. 로컬에서는 끝까지 삭제되는 것을 확인했지만 Cloud Run에서는 미확인.
  - 확인 방법: 배포 후 metrics에서 `delete_ok: false`인 세션을 찾아 `gsutil ls gs://rapid-temp-uploads-match119/sessions/<세션ID>/`로
    원본이 남아 있는지 본다(평소엔 삭제가 0.1~0.2초라 드물다 — 필요하면 일부러 지연시켜 재현).
  - 남는다면: 버킷 수명 주기(누락 대비 1일 경과 후 자동 파기)가 최종 안전망이다. 더 줄여야 하면
    CPU 상시 할당(`--no-cpu-throttling`, 비용 증가) 또는 삭제 한도를 늘리는 쪽을 검토한다.

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
