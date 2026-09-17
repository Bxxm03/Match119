import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import '../theme/tokens.dart';
import '../ui/capsule.dart';
import 'overlay_protocol.dart';

/// 캡슐 오버레이 isolate 진입점.
///
/// 이름 `overlayMain`은 flutter_overlay_window의 네이티브 코드가 하드코딩해
/// 찾으므로 바꾸면 안 된다(`OverlayService.java` 참고).
///
/// 이 isolate에는 플러그인이 등록되지 않는다 — 플러그인 자체 채널인
/// `shareData` / `overlayListener`만 쓸 수 있다. 그래서 캡슐은 녹음도 분석도
/// 직접 하지 않고, 서비스에 명령을 보내고 상태를 받아 그리기만 한다.
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _CapsuleApp());
}

class _CapsuleApp extends StatelessWidget {
  const _CapsuleApp();

  @override
  Widget build(BuildContext context) {
    // 캡슐 말고는 아무것도 칠하지 않아야 한다. 오버레이 창은 캡슐보다 크기
    // 때문에, Scaffold나 MaterialApp의 기본 배경색이 조금이라도 남으면 캡슐
    // 주변이 바랜 사각형으로 보인다. 그래서 Scaffold를 쓰지 않고, InkWell과
    // Tooltip이 필요한 Material 조상만 투명 타입으로 둔다.
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
      ),
      home: const Material(
        type: MaterialType.transparency,
        child: Align(
          alignment: Alignment.centerLeft,
          child: _CapsuleHost(),
        ),
      ),
    );
  }
}

class _CapsuleHost extends StatefulWidget {
  const _CapsuleHost();

  @override
  State<_CapsuleHost> createState() => _CapsuleHostState();
}

class _CapsuleHostState extends State<_CapsuleHost> {
  bool _recording = false;
  int _elapsed = 0;

  @override
  void initState() {
    super.initState();
    FlutterOverlayWindow.overlayListener.listen((data) {
      if (!mounted || data is! Map || data[kState] != true) return;
      setState(() {
        _recording = data[kRecording] == true;
        _elapsed = (data[kElapsedSec] as num?)?.toInt() ?? 0;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(RapidSpace.sm),
      child: Capsule(
        recording: _recording,
        recordedSeconds: _elapsed,
        // 캡슐은 명령만 보낸다. 실제 녹음은 서비스가 한다.
        onMicTap: () => FlutterOverlayWindow.shareData(cmd(kCmdToggleRecord)),
        onExpandTap: () => FlutterOverlayWindow.shareData(cmd(kCmdExpand)),
      ),
    );
  }
}
