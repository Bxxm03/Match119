import 'package:flutter/material.dart';

import '../platform/assistant_controller.dart';
import '../theme/tokens.dart';

/// 스펙 06절 동의 게이트.
///
/// "분석하기"를 누른 직후, 환자 데이터가 클라우드로 나가기 직전에 뜬다.
/// 녹음 자체는 적법하고(본인 참여 대화) 문제가 되는 것은 제3자 AI 서버로의
/// 전송이므로, 전송 직전이 정확한 게이트 지점이다.
///
/// 팝업이 아니라 전체화면이고, 기본 선택·취소·바깥 탭이 없다. 장갑 낀 손의
/// 오탭을 막아야 하고, 법적으로 중요한 선택이 "지나가는 팝업"처럼 보이면
/// 안 되기 때문이다.
class ConsentGate extends StatelessWidget {
  const ConsentGate({super.key});

  @override
  Widget build(BuildContext context) {
    // 뒤로가기로 빠져나가면 선택을 건너뛰는 셈이 되므로 막는다.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: RapidColors.carbon,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.all(RapidSpace.xl),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.shield_outlined,
                        color: RapidColors.amber, size: 40),
                    const SizedBox(height: RapidSpace.xl),
                    const Text(
                      '환자의 동의를 받으셨나요?',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: RapidColors.paper,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: RapidSpace.md),
                    const Text(
                      '동의를 받은 경우에만 대화와 사진을\n분석 서버로 전송합니다.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: RapidColors.fog,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: RapidSpace.xxl),
                    _BigChoice(
                      label: '예',
                      background: RapidColors.vital,
                      foreground: const Color(0xFF062015),
                      onTap: () => Navigator.of(context)
                          .pop(ConsentChoice.granted),
                    ),
                    const SizedBox(height: RapidSpace.md),
                    _BigChoice(
                      label: '아니오',
                      background: RapidColors.graphite2,
                      foreground: RapidColors.paper,
                      onTap: () =>
                          Navigator.of(context).pop(ConsentChoice.denied),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BigChoice extends StatelessWidget {
  const _BigChoice({
    required this.label,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(RapidRadius.button),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RapidRadius.button),
        // 급한 상황에서 확실히 눌리도록 최소 터치 타겟보다 크게 잡는다.
        child: Container(
          height: 72,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: foreground,
            ),
          ),
        ),
      ),
    );
  }
}
