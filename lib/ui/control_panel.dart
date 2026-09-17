import 'package:flutter/material.dart';

import '../platform/assistant_controller.dart';
import '../theme/tokens.dart';

/// 스펙 01절 컨트롤 패널 — 앱 아이콘을 탭했을 때 뜨는 화면.
///
/// 서비스를 켜고 끄고 상태를 확인하는 자리다. 환자별 작업 화면이 아니다.
/// 평소에는 제목과 버튼 두 개만 두고, 준비 항목이 빠졌을 때만 경고 블록을
/// 보여 준다 — 상시 권한 체크리스트는 대원에게 아무 값어치가 없다.
class ControlPanel extends StatefulWidget {
  const ControlPanel({
    super.key,
    required this.controller,
    required this.state,
  });

  final AssistantController controller;
  final AssistantState state;

  @override
  State<ControlPanel> createState() => _ControlPanelState();
}

class _ControlPanelState extends State<ControlPanel> {
  Set<ReadinessItem> _pending = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final pending = await widget.controller.checkReadiness();
    if (mounted) setState(() => _pending = pending);
  }

  /// 스펙 02절 "시작" 흐름 — 부족한 것을 먼저 요청하고, 막는 항목이 전부
  /// 확보되면 기동한다. 권한 팝업이 캡슐 사용 중에 뜨면 그게 곧 처치 방해이므로
  /// 여기서 다 받는다.
  ///
  /// 배터리(blocking=false)는 요청은 하되 거부돼도 시작을 막지 않는다 — 경고
  /// 블록에는 계속 남아 눈에 띄지만, 필수 3개만 있으면 서비스가 켜진다.
  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      var pending = await widget.controller.checkReadiness();
      if (pending.isNotEmpty) {
        pending = await widget.controller.requestReadiness();
      }
      if (!mounted) return;
      setState(() => _pending = pending);
      if (pending.any((item) => item.blocking)) return; // 필수 항목 거부됨.

      await widget.controller.startService();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = widget.state.serviceRunning;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(RapidSpace.xl),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'RAPID',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 4,
                      color: RapidColors.paper,
                    ),
                  ),
                  const SizedBox(height: RapidSpace.sm),
                  Text(
                    running ? '실행 중' : '현장 기록 어시스턴트',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: running ? RapidColors.vital : RapidColors.fog,
                      fontWeight: running ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: RapidSpace.xxl),
                  if (_pending.isNotEmpty) ...[
                    for (final item in _pending) _WarningRow(item: item),
                    const SizedBox(height: RapidSpace.lg),
                  ],
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : running
                            ? widget.controller.stopService
                            : _start,
                    child: Text(running ? '중지' : '시작'),
                  ),
                  const SizedBox(height: RapidSpace.md),
                  OutlinedButton(
                    onPressed: () => _showGuide(context),
                    child: const Text('가이드'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 가이드 콘텐츠는 초기 버전 앱 완성 후 팀이 실제 화면을 녹화해 채운다.
  /// 지금은 진입점만 있으면 되므로 자리만 잡아 둔다.
  void _showGuide(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: RapidColors.graphite,
        title: const Text('가이드'),
        content: const Text('사용 안내 영상이 준비 중입니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }
}

/// 빠진 준비 항목 한 줄 + 설정 바로가기. 뭐가 막혔는지 알려줘야 대원이
/// 어디로 가야 하는지 안다.
class _WarningRow extends StatelessWidget {
  const _WarningRow({required this.item});

  final ReadinessItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: RapidSpace.sm),
      padding: const EdgeInsets.symmetric(
        horizontal: RapidSpace.md,
        vertical: RapidSpace.md,
      ),
      decoration: BoxDecoration(
        color: RapidColors.sirenDim,
        borderRadius: BorderRadius.circular(RapidRadius.button),
        border: Border.all(color: RapidColors.siren.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: RapidColors.siren, size: 18),
          const SizedBox(width: RapidSpace.sm),
          Expanded(
            child: Text(
              '${item.label}이 필요합니다',
              style: const TextStyle(fontSize: 13, color: RapidColors.paper),
            ),
          ),
        ],
      ),
    );
  }
}
