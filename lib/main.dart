import 'dart:io';

import 'package:flutter/material.dart';

import 'data/analysis_api.dart';
import 'platform/assistant_controller.dart';
import 'platform/fake_assistant_controller.dart';
import 'platform/local_assistant_controller.dart';
import 'platform/real_assistant_controller.dart';
import 'theme/tokens.dart';
import 'ui/app_shell.dart';

// 캡슐 오버레이 isolate의 진입점을 여기서 다시 노출해 둔다. 네이티브 코드가
// 이름으로 찾는 함수라, 참조가 없으면 트리 셰이킹에 날아갈 수 있다.
export 'platform/overlay_entry.dart' show overlayMain;

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
const _apiBaseUrl = String.fromEnvironment(
  'RAPID_API',
  defaultValue: 'http://127.0.0.1:8000',
);

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
    final controller = RealAssistantController(apiBaseUrl: _apiBaseUrl);
    await controller.init();
    return controller;
  }

  return LocalAssistantController(api: AnalysisApi(baseUrl: _apiBaseUrl));
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
