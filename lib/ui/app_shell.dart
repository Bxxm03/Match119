import 'package:flutter/material.dart';

import '../platform/assistant_controller.dart';
import 'consent_gate.dart';
import 'control_panel.dart';
import 'work_screens.dart';

/// 컨트롤 패널과 작업 화면 사이를 오가는 껍데기.
///
/// 캡슐이 진짜 OS 오버레이인지에 따라 "축소"의 뜻이 달라진다:
/// - 오버레이 있음(안드로이드): 캡슐은 이미 화면 위에 떠 있다. 앱 창은 항상
///   작업 화면이고, 축소는 앱 창을 내리는 것이다.
/// - 오버레이 없음(데스크톱·Fake): 앱 창 안에 캡슐을 그려 흉내 내고, 축소는
///   그 캡슐 화면으로 돌아가는 것이다.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final AssistantController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// 오버레이가 없는 모드에서만 쓰는 상태 — 앱 창 안에서 캡슐/작업화면을 토글한다.
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AssistantState>(
      stream: widget.controller.states,
      initialData: widget.controller.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? const AssistantState();

        if (!state.serviceRunning) {
          if (_expanded) _expanded = false;
          return ControlPanel(controller: widget.controller, state: state);
        }

        return CapsuleScaffold(
          controller: widget.controller,
          state: state,
          // 진짜 오버레이가 있으면 앱 창은 언제나 작업 화면이다.
          expanded: widget.controller.hasSystemOverlay || _expanded,
          onExpand: () => setState(() => _expanded = true),
          onCollapse: _collapse,
          onAnalyze: () => _askConsent(state),
        );
      },
    );
  }

  Future<void> _collapse() async {
    await widget.controller.collapse();
    if (!mounted) return;
    if (!widget.controller.hasSystemOverlay) {
      setState(() => _expanded = false);
    }
  }

  /// 스펙 06절 — 분석 직전 동의 게이트. 전송 직전이 정확한 게이트 지점이다.
  Future<void> _askConsent(AssistantState state) async {
    if (!state.canAnalyze) return;

    final choice = await Navigator.of(context).push<ConsentChoice>(
      MaterialPageRoute(
        builder: (_) => const ConsentGate(),
        fullscreenDialog: true,
      ),
    );
    if (choice == null || !mounted) return;

    await widget.controller.analyze(choice);
  }
}
