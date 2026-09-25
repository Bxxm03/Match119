# Match119 (RAPID) — 팀 공용 작업 규칙

구급대원과 환자의 대화 녹음·환부 사진을 AI가 분석해 119 구급일지 입력 서식에 맞게 구조화하고,
대원이 확인 후 복사해 기존 119 시스템에 붙여넣도록 돕는 Flutter 태블릿 오버레이 앱.
2026 제2회 Google-아주대 AI융합캡스톤디자인 대회 출품작.

팀: 진용범(총괄·검증), 노연우(GCP 백엔드·Vertex AI), 송민근(프론트엔드)

## 목표 아키텍처 (현재 이 구조로 전환 중)

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
- 현재 `backend/main.py`는 PoC 상태(Gemini Developer API 키 + Files API, multipart 업로드).
  위 구조로 교체하는 것이 진행 중인 작업이다.

## GCP 리소스

| 항목 | 값 |
|---|---|
| 프로젝트 ID | `match119-504015` (같은 이름의 `match119`는 사용하지 않음) |
| 리전 | `asia-northeast3` (서울) — 버킷·Firestore·Cloud Run 모두 동일 |
| 버킷 | `rapid-temp-uploads-match119` (공개 차단, 균일 액세스, 1일 경과 자동 삭제) |
| 런타임 서비스 계정 | `rapid-backend@match119-504015.iam.gserviceaccount.com` |
| 서비스 계정 권한 | 버킷 `storage.objectAdmin`, `datastore.user`, `aiplatform.user`, 자기 자신 `iam.serviceAccountTokenCreator` |

- 서비스 계정 키(JSON)는 만들지도, 공유하지도 않는다. 로컬은 각자 `gcloud auth application-default login`.
- Cloud Run에는 서명용 개인키가 없다. Signed URL은 IAM signBlob 방식
  (`service_account_email` + `access_token` 전달)으로 서명한다.

## 백엔드 (`backend/`)

- Python **3.13** (Dockerfile도 `python:3.13-slim`). 팀원 모두 3.13.x 사용.
- 설정값은 코드에 박지 않고 환경변수로 받는다: `PROJECT_ID`, `REGION`, `BUCKET`, `MODEL`.
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

배포:

```
gcloud run deploy rapid-backend --source backend/ --region asia-northeast3 ^
  --service-account=rapid-backend@match119-504015.iam.gserviceaccount.com ^
  --set-env-vars=PROJECT_ID=match119-504015,REGION=asia-northeast3,BUCKET=rapid-temp-uploads-match119,MODEL=<모델ID>
```

- `--service-account`를 빼먹으면 권한이 넓은 기본 계정으로 돈다. 반드시 지정.
- `min-instances=1`은 시연 당일에만 켠다(무료 한도 소모).

### 반드시 유지할 기존 안전장치 (PoC에서 실제 문제를 겪고 넣은 것)

- 2초 미만 녹음은 모델을 부르지 않고 빈 결과 반환 (`MIN_AUDIO_SECONDS`) — 잡음으로 가짜 응급상황을 지어내는 문제 방지
- `temperature: 0`, 필드별 독립 판단·언급 없는 필드는 빈 문자열 — 환각 억제
- 응답 사용량에 AUDIO 토큰이 없으면 경고 로그 — 오디오가 모델에 안 닿고 답을 지어낸 경우 탐지
- 503(과부하) 최대 2회 재시도, 서버 타임아웃(75s) < 앱 타임아웃(90s)
- onset/last_normal_time은 서버 현재 시각 기준 절대시각 병기
- 분석 성공·실패와 무관하게 `finally`에서 원본 파일 삭제

### 로그·데이터 원칙

- 환자 음성·사진·요약 내용은 영구 저장하지 않는다. Firestore에는 소요시간·성공 여부·파일 크기 같은 비식별 메타데이터만 기록.
- 소요시간은 단계별(업로드/추론/삭제)로 기록한다 — 발표 수치의 실측 근거가 된다.

## 프론트엔드 (Flutter)

- UI는 유지. 서버 통신은 `lib/data/analysis_api.dart`에서만 한다.
- 백엔드 주소는 `--dart-define=RAPID_API=<주소>` (기본값 `http://127.0.0.1:8000`, USB + `adb reverse tcp:8000 tcp:8000`)
- 화면만 볼 때: `--dart-define=RAPID_FAKE=true`

## 용어·표현 규칙 (코드 주석, UI 문구, 문서 모두 적용)

- AI 출력은 **"진단"이 아니라 "중증도 및 의심 질환군 1차 분류(Triage) 보조"**. "AI가 판단/진단한다" 금지. 최종 판단·전송 주체는 항상 대원.
- 중증도 분류 용어는 **Pre-KTAS** (KTAS 아님).
- 기존 119 스마트시스템과는 협력 구도로 서술한다. "대체한다/병목을 만들었다" 같은 대립 표현 금지.
- 실측·검증되지 않은 수치나 기능은 "목업", "자체 측정", "예정"으로 명시한다.
  예: resumable 업로드를 구현하기 전에는 "이어올리기"를 완료형으로 쓰지 않는다.
  예: GCS 수명 주기 규칙은 "즉시"가 아니라 "누락 대비 1일 경과 후 자동 파기"다.
- 우리의 GCS 원본 삭제와 Google 측 ZDR 설정은 다른 개념이다. 발표에서는 "원본 즉시 삭제"로 표현.

## Git 규칙

- main에 직접 push하지 않는다. `feature/<작업명>` 브랜치 → PR → 리뷰 후 병합.
- 커밋 메시지는 한글로 작성한다.
- 줄바꿈은 `.gitattributes`로 LF 통일. push 이후 커밋을 수정(amend, 강제 push)하지 않는다.
- 비밀값(`.env`, 서비스 계정 키)은 커밋하지 않는다.
