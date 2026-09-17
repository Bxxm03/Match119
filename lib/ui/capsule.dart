import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 스펙 04절 캡슐 — 축소 상태의 RAPID UI 전부.
///
/// 알약 하나에 `[마이크 | 확대]`가 나란히 들어가고, 캡슐 전체를 드래그해
/// 옮긴다. 마이크와 확대를 별개 버블 두 개로 두지 않은 이유는 장갑 낀 손에
/// 두 개의 큰 타겟이 더 낫고, 한 버블에 두 동작을 넣으면 오조작 위험이
/// 커지기 때문이다.
///
/// 실제 안드로이드에서는 이 위젯이 시스템 오버레이 창 안에 그려진다.
/// 기기 없이 볼 때는 화면 안에 떠 있는 것으로 대신한다.
class Capsule extends StatelessWidget {
  const Capsule({
    super.key,
    required this.recording,
    required this.recordedSeconds,
    required this.onMicTap,
    required this.onExpandTap,
  });

  final bool recording;
  final int recordedSeconds;
  final VoidCallback onMicTap;
  final VoidCallback onExpandTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: RapidColors.graphite,
            borderRadius: BorderRadius.circular(RapidRadius.capsule),
            border: Border.all(color: RapidColors.line),
            // 그림자는 아주 좁게. 오버레이 창은 캡슐보다 크기 때문에, 번지는
            // 그림자가 투명 영역까지 퍼지면 119 화면 위에 "바랜 사각형"처럼
            // 보인다. 떠 있는 느낌만 낼 정도로 줄인다.
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CapsuleHalf(
                icon: recording ? Icons.stop_rounded : Icons.mic_rounded,
                // 스펙 10-1: 녹음 중 = siren. "지금 주목" 신호.
                color: recording ? RapidColors.siren : RapidColors.paper,
                tooltip: recording ? '녹음 정지' : '녹음 시작',
                onTap: onMicTap,
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(RapidRadius.capsule),
                ),
              ),
              Container(width: 1, height: 28, color: RapidColors.line),
              _CapsuleHalf(
                icon: Icons.open_in_full_rounded,
                color: RapidColors.paper,
                tooltip: '확대',
                onTap: onExpandTap,
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(RapidRadius.capsule),
                ),
              ),
            ],
          ),
        ),
        if (recording) ...[
          const SizedBox(width: RapidSpace.sm),
          _RecordingBadge(seconds: recordedSeconds),
        ],
      ],
    );
  }
}

class _CapsuleHalf extends StatelessWidget {
  const _CapsuleHalf({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
    required this.borderRadius,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: SizedBox(
          // 장갑 낀 손 기준 최소 터치 타겟.
          width: RapidSize.minTouchTarget,
          height: RapidSize.minTouchTarget,
          child: Icon(icon, color: color, size: 24),
        ),
      ),
    );
  }
}

/// 녹음 중임을 캡슐 옆에 붙여 알린다. 대원이 화면을 안 보고 있어도
/// 곁눈으로 확인할 수 있어야 한다.
class _RecordingBadge extends StatelessWidget {
  const _RecordingBadge({required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RapidSpace.md,
        vertical: RapidSpace.sm,
      ),
      decoration: BoxDecoration(
        color: RapidColors.sirenDim,
        borderRadius: BorderRadius.circular(RapidRadius.capsule),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _PulsingDot(),
          const SizedBox(width: RapidSpace.sm),
          Text(
            formatDuration(seconds),
            style: const TextStyle(
              color: RapidColors.siren,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              // 자리수가 흔들리면 눈에 거슬리므로 고정폭.
              fontFamily: RapidFont.mono,
            ),
          ),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.25).animate(_c),
      child: Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(
          color: RapidColors.siren,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// `m:ss`. 녹음 길이 표시에 쓴다.
String formatDuration(int totalSeconds) {
  final m = totalSeconds ~/ 60;
  final s = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}
