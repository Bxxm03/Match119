# Match119 (RAPID) — 팀 공용 작업 규칙

구급대원과 환자의 대화 녹음·환부 사진을 AI가 분석해 119 구급일지 입력 서식에 맞게 구조화하고,
대원이 확인 후 복사해 기존 119 시스템에 붙여넣도록 돕는 Flutter 태블릿 오버레이 앱.
2026 제2회 Google-아주대 AI융합캡스톤디자인 대회 출품작.

팀: 진용범(총괄·검증), 노연우(GCP 백엔드·Vertex AI), 송민근(프론트엔드)

## 목표 아키텍처 (현재 이 구조로 전환 중)

자세한 설계 배경(각 구성 요소를 쓰는 이유)은 `docs/architecture.md`, 흐름도는 `docs/sequence-diagram.jpg` 참고.

```
Flutter 앱 ──(1) 업로드 주소 요청──▶ Cloud Run
          ◀── Signed URL ──────────
          ──(2) 오디오·사진 직접 PUT ──▶ Cloud Storage (임시 보관)
          ──(3) 분석 요청(객체 이름) ──▶ Cloud Run
                                         ├─ Firestore에서 최신 프롬프트 조회
                                         ├─ Vertex AI(Gemini)에 프롬프트 + gs:// URI 전달
                                         ├─ 결과 수신 즉시 GCS 원본 삭제 (finally)
                                         └─ Firestore에 비식별 메타데이터 기록
          ◀── 구조화 JSON ─────────
```

- 범위: 위 클라우드 파이프라인까지. 온디바이스(Gemini Nano)는 현재 범위 밖이며,
  동의 거부 분기는 "준비 중" 상태로 둔다.
- `backend/`는 위 구조로 교체됨(`feature/vertex-backend`). 앱(`lib/data/analysis_api.dart`)은 아직
  구 multipart 방식이라 새 흐름으로 바꾸는 작업이 남아 있다 — `docs/progress.md` 참고.

## GCP 리소스

| 항목 | 값 |
|---|---|
| 프로젝트 ID | `match119-504015` (같은 이름의 `match119`는 사용하지 않음) |
| 리전 | 버킷·Firestore·Cloud Run은 서울(`asia-northeast3`), **AI 추론만 도쿄(`asia-northeast1`)**. Vertex AI 호출 리전은 별도 값(`VERTEX_LOCATION`) — 아래 "Vertex AI 모델" 참고 |
| 버킷 | `rapid-temp-uploads-match119` (공개 차단, 균일 액세스, 1일 경과 자동 삭제) |
| 런타임 서비스 계정 | `rapid-backend@match119-504015.iam.gserviceaccount.com` |
| 서비스 계정 권한 | 버킷 `storage.objectAdmin`, `datastore.user`, `aiplatform.user`, 자기 자신 `iam.serviceAccountTokenCreator` |

- 서비스 계정 키(JSON)는 만들지도, 공유하지도 않는다. 로컬은 각자 `gcloud auth application-default login`.
- Cloud Run에는 서명용 개인키가 없다. Signed URL은 IAM signBlob 방식
  (`service_account_email` + `access_token` 전달)으로 서명한다.
- 로컬에서 `/api/uploads`를 쓰려면 **본인 계정**에도 `rapid-backend` 서비스 계정에 대한
  `iam.serviceAccountTokenCreator`가 있어야 한다(없으면 서명 단계에서 403).

## Vertex AI 모델

| 항목 | 값 |
|---|---|
| 사용 모델 | `gemini-3.5-flash` (GA) — 2026-10-02 `gemini-2.5-flash`에서 운영 전환(리비전 `rapid-backend-g35-2567176`) |
| Vertex 호출 리전 | `asia-northeast1` (도쿄) — 2026-09-28 서울에서 전환 |
| 모델 종료(retirement) 예정일 | **2027-05-19 이후** (이전 모델 `gemini-2.5-flash`는 **2026-10-20**) |
| thinking 설정 | `thinking_level=MINIMAL` (Gemini 3 계열은 thinking을 끌 수 없음, MINIMAL이 최소) |

- 서울(`asia-northeast3`)에는 `gemini-3.5-flash`가 제공되지 않는다(공식 문서 기준, 도쿄는 제공).
- 2.5 vs 3.5 비교(자체 측정, 케이스당 1회)는 `docs/progress.md` "모델 전환: 2.5-flash → 3.5-flash" 참고.

### 롤백 (3.5 → 2.5)

- 기본: 2.5 리비전(`rapid-backend-00002-djk`, 지우지 않고 남겨 둠)으로 트래픽을 되돌린다.
  `gcloud run services update-traffic rapid-backend --region asia-northeast3 --project match119-504015 --to-revisions=rapid-backend-00002-djk=100`
- 또는 코드 수정 없이 `--update-env-vars=MODEL=gemini-2.5-flash`로 재배포한 뒤 그 리비전으로 트래픽을 옮긴다.
  코드가 모델 이름을 보고 thinking 방식을 고른다(2.5는 `thinking_budget=0`, Gemini 3 계열은 `thinking_level`).
  모델에 맞지 않는 쪽 환경변수(`THINKING_LEVEL`·`THINKING_BUDGET`)가 남아 있어도 기동을 막지 않고 무시한다.
- **2.5로 롤백할 수 있는 기한은 2026-10-20(2.5 종료일, 공식 문서 기준)까지다.**

### 서울 → 도쿄 전환 근거 (2026-09-28, 자체 측정)

- 서울(`asia-northeast3`)의 `gemini-2.5-flash`가 **429 RESOURCE_EXHAUSTED를 반복**했다 — 스모크 테스트
  4회(약 22분, 16:40~17:03), HTTP 호출 12번 모두 429. 429 하나에 6~9초씩 걸려 요청마다 24~29초 뒤 실패.
- 콘솔 할당량 화면의 서울 사용률은 **0.05%** — 우리 할당량 문제가 아니라 리전 공유 용량 부족(조정 불가 시스템 한도)으로 판단.

### 다른 모델 후보 (2026-10-01~02 확인)

- `gemini-3.8-flash`는 도쿄·서울 미제공(404) — global·us·eu만 제공되어 쓰지 않는다.
- **`global` 엔드포인트는 사용 금지.** 처리 리전을 보장하지 않아 "특정 리전에서 처리한다"고 말할 수 없게 된다.

### 모델 호출 시 주의사항 (검증 중 발견)

- thinking은 최소로 둔다 — 2.5 계열은 `thinkingBudget: 0`, Gemini 3 계열은 `thinkingLevel: MINIMAL`.
  Gemini 3 계열에 `thinkingBudget`을 보내면 안 된다(3.5-flash 오디오 요청에서 간헐적 400 "Thinking budget is not
  supported for this model", 2026-10-01 자체 측정). 실제로 보낸 값과 thinking 토큰은 metrics `thinking_mode`·
  `thinking_level`·`thinking_budget`·`thoughts_tokens`에 기록된다. thinking을 켜 두면 `maxOutputTokens`가 thinking에
  먼저 소모되어 `finishReason: MAX_TOKENS`로 빈 응답이 나올 수 있다 — `maxOutputTokens`는 응답 스키마
  전체가 들어갈 만큼 넉넉히 잡을 것.
- 0.1초짜리 무음 오디오를 넣어도 모델이 소리를 지어냈다(모델마다 다른 내용). `MIN_AUDIO_SECONDS`
  가드는 모델을 바꿔도 반드시 유지한다.

## 백엔드 (`backend/`)

- Python **3.13** (Dockerfile도 `python:3.13-slim`). 팀원 모두 3.13.x 사용.
- 설정값은 코드에 박지 않고 환경변수로 받는다. 필수값이 빠지면 서버가 기동하지 않는다.

| 변수 | 필수 | 예 / 설명 |
|---|---|---|
| `PROJECT_ID` | ✔ | `match119-504015` |
| `REGION` | ✔ | `asia-northeast3` — 버킷·Firestore·Cloud Run 리전 |
| `BUCKET` | ✔ | `rapid-temp-uploads-match119` |
| `MODEL` | ✔ | `gemini-3.5-flash` — 별칭 금지, 모델 ID 그대로. 롤백은 `gemini-2.5-flash`(2026-10-20까지). 코드에 기본값 없음 |
| `VERTEX_LOCATION` | ✔ | `asia-northeast1`(도쿄) — Vertex AI 호출 리전. `REGION`과 분리해서, 비상 전환 시 코드 수정 없이 `VERTEX_LOCATION`과 `MODEL`만 바꿔 재배포한다. `global`이면 기동 거부 |
| `APP_TOKEN` | ✔ | 앱과 공유하는 토큰(`X-RAPID-Token` 헤더). **무단 호출 방지용 최소 보호**이지 보안 인증이 아니다(APK에서 추출 가능). 커밋 금지 |
| `SIGNER_EMAIL` | 로컬만 | `rapid-backend@match119-504015.iam.gserviceaccount.com` — 로컬 ADC(사용자 계정)에서 Signed URL 서명 주체. Cloud Run에서는 비워 둔다(런타임 서비스 계정 자동 사용) |
| `THINKING_BUDGET` | | **2.5 계열 전용** thinking 토큰 한도. 비우면 `0`(끔, 운영값). 비교 실험할 때만 바꾸고, 값은 metrics `thinking_budget`에 기록된다. Gemini 3 계열에서는 무시 |
| `THINKING_LEVEL` | | **Gemini 3 계열 전용** thinking 수준(`MINIMAL`/`LOW`/`MEDIUM`/`HIGH`). 비우면 `MINIMAL`(운영값). 비교 실험할 때만 바꾸고, 값은 metrics `thinking_level`에 기록된다. 2.5 계열에서는 무시. Cloud Run에는 설정하지 않는다 |
| `PROMPT_SOURCE` | | 프롬프트 출처. 비우면 `firestore`(운영값). `builtin`이면 Firestore를 읽지 않고 `prompts.py`의 내장 기본 프롬프트(`version=builtin`)만 쓴다. 로컬 비교 실험용 — Cloud Run에는 설정하지 않는다 |
| `PROMPT_DOC` | | Firestore `prompts` 컬렉션에서 읽을 문서 이름. 비우면 `current`(운영값). 초안 문서(예: `draft`)를 운영 문서 건드리지 않고 시험할 때만 바꾼다(`/` 불가). `PROMPT_SOURCE=builtin`이면 무시. Cloud Run에는 설정하지 않는다 |

- 로컬은 `backend/.env`에 위 값을 넣는다(`.gitignore`·`.dockerignore`에 제외돼 있음).
- 프롬프트는 Firestore `prompts/current`(`template`, `version`)에서 읽는다. 서버가 1분간 캐시하므로
  수정은 "즉시"가 아니라 **캐시 TTL(1분) 내 반영**된다. 문서가 없거나 못 읽으면 `backend/prompts.py`의
  내장 기본 프롬프트(`version=builtin`)를 쓴다. 기본 프롬프트 업로드: `python seed_prompt.py <버전>`.
- 응답 스키마(8필드)는 앱 파싱과 맞물린 계약이라 코드(`backend/prompts.py`)가 소유한다.
  칸 설명을 고칠 때는 `prompts.py`의 `SCHEMA_VERSION`을 올린다 — metrics `schema_version`에 기록된다.
- 로컬 경로(`C:\Users\...` 등)를 코드에 하드코딩하지 않는다 — 컨테이너에서 깨진다.
- Vertex 모델은 **모델 ID를 명시**한다. `gemini-flash-latest` 같은 별칭은 Developer API 전용이라 Vertex에서 쓰지 않는다.

로컬 실행 (Windows cmd 기준):

```
cd backend
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
gcloud auth application-default login
uvicorn main:app --reload --port 8000
```

스모크 테스트 (서버를 띄운 상태에서, 다른 창의 `backend/`에서):

```
python scripts/smoke_test.py <오디오.m4a|.wav> [--photo 사진.jpg ...] [--duration 초] [--server 주소]
```

- uploads → PUT → analyze 후 원본 삭제·metrics·prompt_version까지 확인하고, 토큰 없음(401)·1초 녹음도 점검한다.
- 이 스크립트로 생긴 metrics 기록은 지우지 않는다. `test: true`와 `case`(`normal` / `failure_check`)로
  실제 기록과 구분하므로, 발표 수치를 집계할 때는 `test == true`를 제외한다.

처음 배포(서비스를 새로 만들 때만):

```
gcloud run deploy rapid-backend --source backend/ --region asia-northeast3 ^
  --service-account=rapid-backend@match119-504015.iam.gserviceaccount.com ^
  --allow-unauthenticated ^
  --set-env-vars=PROJECT_ID=match119-504015,REGION=asia-northeast3,BUCKET=rapid-temp-uploads-match119,MODEL=gemini-3.5-flash,VERTEX_LOCATION=asia-northeast1,APP_TOKEN=<공유토큰>
```

- `--service-account`를 빼먹으면 권한이 넓은 기본 계정으로 돈다. 반드시 지정.
- `--allow-unauthenticated`는 앱이 IAM 인증 없이 부르기 때문에 필요하다. 대신 `/api/uploads`·`/api/analyze`는
  `APP_TOKEN` 공유 토큰(무단 호출 방지용 최소 보호)으로 막는다. `/api/health`만 토큰 없이 열려 있다.
- `APP_TOKEN` 실제 값은 배포 명령·문서에 적어 커밋하지 않는다. `SIGNER_EMAIL`은 Cloud Run에 넣지 않는다.
- `min-instances=1`은 시연 당일에만 켠다(무료 한도 소모).

이후 배포(2026-10-02부터 쓰는 방식 — 기존 서비스 갱신):

- `--set-env-vars`는 쓰지 않는다(목록에 없는 변수가 지워짐). 바꿀 변수만 `--update-env-vars`로 넘긴다.
- 커밋을 고정해서 올린다: `git archive <커밋> backend`를 임시 폴더에 풀고 그 폴더를 `--source`로 쓴다(작업 트리 파일이 섞이지 않게).
  올리기 전에 임시 폴더에 `.env`·`dart_defines.json`·녹음 파일이 없는지 확인한다.
- `--revision-suffix=<이름> --tag=<태그> --no-traffic`으로 먼저 올리고, 태그 URL로 확인한 뒤
  `gcloud run services update-traffic … --to-revisions=<새 리비전>=100`으로 옮긴다.
- 트래픽이 리비전 고정 방식이라 **새 리비전은 배포만으로는 트래픽을 받지 않는다** — 반드시 `update-traffic`까지 한다.

### 반드시 유지할 기존 안전장치 (PoC에서 실제 문제를 겪고 넣은 것)

- 2초 미만 녹음은 모델을 부르지 않고 빈 결과 반환 (`MIN_AUDIO_SECONDS`) — 잡음으로 가짜 응급상황을 지어내는 문제 방지
- `temperature: 0`, 필드별 독립 판단·언급 없는 필드는 빈 문자열 — 환각 억제
- 응답 사용량에 AUDIO 토큰이 없으면 경고 로그 — 오디오가 모델에 안 닿고 답을 지어낸 경우 탐지
- Vertex AI 429(할당량 초과)·503(과부하)는 최대 2회 재시도 — 대기 시간을 두 배씩 늘리고(지터 포함),
  요청 예산 안에 남은 시간이 있을 때만 재시도한다
- 요청 전체 예산 75초(업로드 확인·프롬프트 조회·모델 호출, 모델에는 남은 시간만) < 앱 타임아웃(90s).
  원본 삭제·메타데이터 기록은 예산이 바닥나도 반드시 시도하되 짧은 한도로 묶어 최악 86초
- onset/last_normal_time은 서버 현재 시각 기준 절대시각 병기
- 분석 성공·실패와 무관하게 `finally`에서 원본 파일 삭제

### 로그·데이터 원칙

- 환자 음성·사진·요약 내용은 영구 저장하지 않는다. Firestore에는 소요시간·성공 여부·파일 크기 같은 비식별 메타데이터만 기록.
- 소요시간은 단계별(업로드/추론/삭제)로 기록한다 — 발표 수치의 실측 근거가 된다.

## 프론트엔드 (Flutter)

- UI는 유지. 서버 통신은 `lib/data/analysis_api.dart`에서만 한다.
- 실행 설정은 레포 루트의 `dart_defines.json`에 둔다. `dart_defines.example.json`을 복사해 값을 채운다
  (`dart_defines.json`은 `.gitignore`에 제외돼 있어 커밋되지 않는다).

  | 키 | 값 |
  |---|---|
  | `RAPID_API` | 백엔드 주소. Cloud Run이면 서비스 URL, 로컬 서버면 `http://127.0.0.1:8000`(USB + `adb reverse tcp:8000 tcp:8000`). 비우면 기본값 `http://127.0.0.1:8000` |
  | `RAPID_TOKEN` | `APP_TOKEN`과 같은 값. `X-RAPID-Token` 헤더로 전송(무단 호출 방지용 최소 보호). 커밋·로그 금지 |

  ```
  flutter run --dart-define-from-file=dart_defines.json
  ```
- 화면만 볼 때: `--dart-define=RAPID_FAKE=true`

## 용어·표현 규칙 (코드 주석, UI 문구, 문서 모두 적용)

- AI 출력은 **"진단"이 아니라 "중증도 및 의심 질환군 1차 분류(Triage) 보조"**. "AI가 판단/진단한다" 금지. 최종 판단·전송 주체는 항상 대원.
- 중증도 분류 용어는 **Pre-KTAS** (KTAS 아님).
- 기존 119 스마트시스템과는 협력 구도로 서술한다. "대체한다/병목을 만들었다" 같은 대립 표현 금지.
- 실측·검증되지 않은 수치나 기능은 "목업", "자체 측정", "예정"으로 명시한다.
  예: resumable 업로드를 구현하기 전에는 "이어올리기"를 완료형으로 쓰지 않는다.
  예: GCS 수명 주기 규칙은 "즉시"가 아니라 "누락 대비 1일 경과 후 자동 파기"다.
- 우리의 GCS 원본 삭제와 Google 측 ZDR 설정은 다른 개념이다. 발표에서는 "원본 즉시 삭제"로 표현.
- 리전은 **"원본 파일 보관·삭제는 서울 리전, AI 추론은 도쿄 리전"**으로 표현한다.
  "모든 처리를 서울에서 한다"거나 리전을 뭉뚱그려 말하지 않는다.
- 공유 토큰(`APP_TOKEN`)은 "보안 인증"이 아니라 **"무단 호출 방지용 최소 보호"**로 쓴다.
- Firestore 프롬프트 수정은 "즉시 반영"이 아니라 **"캐시 TTL(1분) 내 반영"**으로 쓴다.

## Git 규칙

- main에 직접 push하지 않는다. `feature/<작업명>` 브랜치 → PR → 리뷰 후 병합.
- 커밋 메시지는 한글로 작성한다.
- 줄바꿈은 `.gitattributes`로 LF 통일. push 이후 커밋을 수정(amend, 강제 push)하지 않는다.
- 비밀값(`.env`, 서비스 계정 키)은 커밋하지 않는다.
