import 'dart:io';

import 'package:flutter/material.dart';

import 'data/analysis_api.dart';
import 'platform/assistant_controller.dart';
import 'platform/fake_assistant_controller.dart';
import 'platform/local_assistant_controller.dart';
import 'platform/overlay_entry.dart' as overlay;
import 'platform/real_assistant_controller.dart';
import 'theme/tokens.dart';
import 'ui/app_shell.dart';

/// 캡슐 오버레이 isolate의 진입점.
///
/// flutter_overlay_window의 네이티브 코드는 `overlayMain`을 **루트 라이브러리
/// (main.dart)** 에서 이름으로 찾는다. `export`로 재노출만 하면 디버그(JIT)에서는
/// 찾히지만 릴리즈(AOT)에서는 루트 라이브러리에 심볼이 없어 캡슐이 뜨지 않는다.
/// 그래서 여기에 직접 정의하고 `vm:entry-point`로 트리 셰이킹을 막는다.
/// 실제 구현은 `platform/overlay_entry.dart`에 있다.
@pragma('vm:entry-point')
void overlayMain() => overlay.overlayMain();

/// 분석 서버 주소. `--dart-define=RAPID_API=...`로 덮어쓴다.
///
/// 기본값 `127.0.0.1:8000`이 실기기에서도 통하는 이유는 USB로 연결한 뒤
/// `adb reverse tcp:8000 tcp:8000`을 걸어 두기 때문이다. 기기의 로컬 포트가
/// 개발 PC로 전달되므로 방화벽을 열 필요도, 같은 와이파이일 필요도 없다.
///
/// 연결 방식 세 가지:
/// - USB + `adb reverse` — 기본값 그대로. 개발 중 반복 테스트용.
/// - 같은 와이파이 — `RAPID_API=http://<개발PC LAN IP>:8000`. PC 방화벽에서
///   8000 포트를 열어야 한다.
/// - Cloud Run — `RAPID_API=https://<서비스주소>`. 시연처럼 PC가 없는 곳에서.
///
/// `dart_defines.json`에 빈 문자열로 두면 `defaultValue`가 적용되지 않고 ""가
/// 들어오므로, 빈 값도 기본값으로 돌린다.
const _apiBaseUrlDefine = String.fromEnvironment('RAPID_API');
const _apiBaseUrl = _apiBaseUrlDefine == ''
    ? 'http://127.0.0.1:8000'
    : _apiBaseUrlDefine;

/// 백엔드 `APP_TOKEN`과 같은 공유 토큰. `--dart-define=RAPID_TOKEN=...`
/// (보통 `dart_defines.json`)으로 받아 `X-RAPID-Token` 헤더로 보낸다.
/// 무단 호출 방지용 최소 보호일 뿐 보안 인증이 아니다(APK에서 추출 가능).
/// 값은 로그에 남기지 않는다.
const _apiToken = String.fromEnvironment('RAPID_TOKEN');

/// 컨트롤러를 Fake로 강제할 때 쓴다: `--dart-define=RAPID_FAKE=true`.
/// 백엔드를 띄우지 않고 화면만 볼 때 편하다.
const _forceFake = bool.fromEnvironment('RAPID_FAKE');

/// 오버레이·포그라운드 서비스를 끄고 일반 창 앱으로 돌릴 때 쓴다:
/// `--dart-define=RAPID_NO_OVERLAY=true`. 네이티브 계층을 의심할 때 이걸로
/// 돌려 보면 문제가 오버레이 쪽인지 그 아래인지 가를 수 있다.
const _noOverlay = bool.fromEnvironment('RAPID_NO_OVERLAY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final controller = await _buildController();
  runApp(RapidApp(controller: controller));
}

Future<AssistantController> _buildController() async {
  if (_forceFake) return FakeAssistantController();

  // 안드로이드에서만 시스템 오버레이와 포그라운드 서비스가 성립한다.
  // 데스크톱(개발 노트북)에서는 녹음·분석만 실제로 도는 구현을 쓴다.
  if (Platform.isAndroid && !_noOverlay) {
    final controller = RealAssistantController(
      apiBaseUrl: _apiBaseUrl,
      apiToken: _apiToken,
    );
    await controller.init();
    return controller;
  }

  return LocalAssistantController(
    api: AnalysisApi(baseUrl: _apiBaseUrl, token: _apiToken),
  );
}

class RapidApp extends StatefulWidget {
  const RapidApp({super.key, required this.controller});

  final AssistantController controller;

  @override
  State<RapidApp> createState() => _RapidAppState();
}

class _RapidAppState extends State<RapidApp> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RAPID',
      debugShowCheckedModeBanner: false,
      theme: buildRapidTheme(),
      home: AppShell(controller: widget.controller),
    );
  }
}
