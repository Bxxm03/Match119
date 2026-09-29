# RAPID (Match119) — 요구사항 / 현재 구현 상태

> 이 문서는 "이렇게 만들 것이다"가 아니라 **지금 리포지토리에 실제로 구현되어 있는 것**을 기준으로 작성한다. 계획/미착수 항목은 마지막 절에 따로 표시한다.

## 1. 목적

구급대원이 환자·보호자와 나누는 대화와 현장 사진을 듣고 보고, 기존 119 구급시스템 화면 위에 떠 있는 캡슐(오버레이)을 통해 구조화된 환자 기록 6개 필드를 자동으로 채워 클립보드로 넘겨준다. 대원은 그 결과를 기존 119 시스템에 붙여넣기만 하면 된다.

## 2. 핵심 기능 (구현됨)

- **캡슐 오버레이**: 다른 앱(119 시스템) 위에 항상 떠 있는 알약 모양 UI. 마이크(녹음 시작/정지)와 확대(작업 화면 열기) 두 개 버튼만 있음.
- **녹음**: 캡슐 마이크로 시작/정지. 백그라운드(포그라운드 서비스)에서 계속되며, 앱을 최소화해도 끊기지 않음.
- **사진 첨부**: 카메라로 촬영, 최대 3장. 갤러리 선택은 지원하지 않음(현장 촬영만).
- **AI 분석**: 녹음+사진을 백엔드로 보내 Gemini로 분석, 아래 6개 필드 + AI 종합소견/근거를 구조화된 JSON으로 받는다.
  - 주증상, 과거력(F/U병원), 발병시점(onset), 마지막 정상확인시간(LNT), 보호자, 기타
  - 발병시점/LNT는 "20분 전"처럼 상대시간으로 말해도 서버 시각 기준 절대시각으로 환산해 `원표현(HH:MM)` 형식으로 표기
  - 각 필드는 대화에 실제 언급된 것만 채움 — 애매하거나 짧은 녹음(2초 미만)은 추측해서 채우지 않고 빈 값 반환
- **결과 확인/편집**: 분석 결과를 화면에서 필드별로 확인·수정 가능.
- **복사**: "복사"(AI 소견 포함) / "사실만 남기기"(AI 소견 제외) 두 버튼. 누르면 클립보드에 복사되고 자동으로 캡슐이 축소됨.
- **새 케이스 전환**: 결과가 남아있는 동안 캡슐 마이크 아이콘이 새로고침 모양(강조색)으로 바뀌어, 눌렀을 때 이전 케이스가 지워지고 새로 시작됨을 시각적으로 알려준다.
- **권한 관리**: 마이크·카메라·오버레이 권한, 배터리 최적화 제외 요청을 "시작" 한 번으로 처리. 배터리 최적화는 거부돼도 서비스 시작을 막지 않음(선택 항목).
- **개인정보 처리**: 녹음 파일은 분석 후 기기에서 삭제. 백엔드는 Gemini Files API에 업로드한 사본을 분석 직후 항상 삭제(Zero Data Retention).

## 3. 시스템 구성 (현재 실제 구조)

```
[Flutter 앱]
  ├─ 메인 isolate      : UI, 권한 요청, 사진 촬영(카메라는 Activity 필요)
  ├─ 오버레이 isolate  : 캡슐 렌더링만(플러그인 미등록, 명령 송수신만 가능)
  └─ 포그라운드서비스 isolate : 녹음·분석 상태 소유, 백엔드 HTTP 호출

[백엔드: FastAPI (backend/main.py)]
  ├─ POST /api/analyze : 오디오+사진 받아 Gemini Files API 업로드 → generateContent 호출 → 결과 JSON 반환 → 업로드 파일 삭제
  ├─ GET  /api/health  : 백엔드 연결 확인
  └─ GET  /            : 파일럿 웹 페이지(web/index.html) 서빙 — 폰 앱과 무관한 브라우저 테스트용

[Gemini API (공개 Developer API, generativelanguage.googleapis.com)]
  └─ 모델: 환경변수 GEMINI_MODEL로 지정(기본값 gemini-flash-latest, 현재 운영값은 .env에서 관리)
```

배포 형태는 아직 확정되지 않음 — 개발 중에는 로컬 백엔드 + `adb reverse`(USB) 또는 cloudflared 임시 터널로 폰과 연결한다. 둘 다 이 개발 PC가 켜져 있어야 동작하는 임시 방식이다.

## 4. 앱 요구사항

- **플랫폼**: Android만 지원(iOS 미구현). Flutter SDK `^3.13.2`.
- **패키지**: `applicationId = kr.match119.rapid_app`, `compileSdk = 37`(고정, `permission_handler`가 37 이상 요구). minSdk/targetSdk는 Flutter 툴체인 기본값을 따름.
- **필요 권한**(AndroidManifest): `RECORD_AUDIO`, `CAMERA`, `SYSTEM_ALERT_WINDOW`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_SPECIAL_USE`, `POST_NOTIFICATIONS`, `WAKE_LOCK`.
- **핵심 의존 패키지**: `flutter_overlay_window ^0.5.0`, `flutter_foreground_task ^11.0.3`, `record ^7.1.1`, `permission_handler ^13.0.2`, `image_picker ^1.2.3`, `path_provider ^2.1.6`, `http ^1.6.0`.
- **백엔드 주소 설정**: 빌드 시 `--dart-define=RAPID_API=<주소>`로 지정. 생략하면 `http://127.0.0.1:8000`(로컬/adb reverse 전용) 기본값 사용.

## 5. 백엔드 요구사항

- **런타임**: Python 3.11, FastAPI + uvicorn. 의존성은 `backend/requirements.txt` 참고.
- **환경변수**(`.env`, 저장소에 커밋되지 않음): `GEMINI_API_KEY`(필수), `GEMINI_MODEL`(선택, 기본값 `gemini-flash-latest`).
- **Gemini 호출 설정**: `thinkingConfig.thinkingBudget: 0`(추론 비활성화, 응답속도 우선), `temperature: 0`(환각 억제). 503 응답 시 최대 2회 재시도.
- **짧은 녹음 처리**: 클라이언트가 보낸 `duration_seconds`가 2초 미만이면 Gemini를 호출하지 않고 빈 결과를 바로 반환.
- **인증**: 없음 — `/api/analyze`는 누구나 호출 가능한 상태(아래 알려진 제약 참고).

## 6. 알려진 제약 / 한계

- **릴리즈 빌드 + 삼성 기기 조합에서 오버레이 캡슐이 렌더링되지 않는 문제**가 있음(`flutter_overlay_window` 플러그인의 알려진 미해결 이슈로 추정, [X-SLAYER/flutter_overlay_window#5](https://github.com/X-SLAYER/flutter_overlay_window/issues/5)). 현재는 디버그 빌드로 우회해서 사용 중이며, 릴리즈 빌드 자체의 근본 해결책은 없음.
- **백엔드에 인증·요청 제한이 없음** — 배포 주소가 공개되면 누구나 Gemini API 호출을 발생시켜 비용을 소모시킬 수 있음. 정식 배포 전 최소한의 인증 추가가 필요함.
- **사용량/처리시간 지표를 수집하지 않음** — 콘솔 로그로만 남고 영구 저장되지 않음. 효과 측정(타이핑 시간 단축 등)을 위한 데이터가 현재 쌓이지 않음.
- **백엔드가 개발 PC에 의존** — 로컬 백엔드 + adb reverse/cloudflared 방식은 그 PC가 켜져 있고 네트워크가 살아있어야만 동작. 고정 주소가 없어 시연 때마다 주소가 바뀔 수 있음.

## 7. 스코프 밖 (미구현, 계획만 있음)

- **Cloud Run 정식 배포** — 지금 있는 백엔드 로직을 그대로 고정 주소로 올리는 작업. 결제 계정 연결이 선행되어야 함(현재 미연결).
- **Cloud Storage + Vertex AI + Firestore 기반 아키텍처** — 별도 설계 문서(`Match119 전체 시스템 아키텍처_온디바이스제외.docx`)에 정의된 실서비스용 아키텍처. Signed URL 직접 업로드, 동적 프롬프트 관리(Firestore), 비식별 감사 로그 수집을 포함. 단계별 마이그레이션 계획만 논의된 상태이며 코드 작업은 시작 전.
- **온디바이스(오프라인) 모드** — 환자 동의 거부 시 네트워크 없이 처리하는 경로. 프로젝트 초기 스코프에서 명시적으로 제외됨.
- **웹 페이지(`web/index.html`)의 실제 서비스 반영** — 현재는 백엔드 개발/테스트 편의용으로만 서빙되며, 폰 앱 기능과는 무관함.
