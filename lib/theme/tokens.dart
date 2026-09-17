import 'package:flutter/material.dart';

/// 스펙 10-1 디자인 토큰. 위젯에서 색·간격을 하드코딩하지 말고 여기서만 가져온다.
///
/// 다크 온리다 — 구급 활동 상당수가 차내·야간이고, 다크 캡슐이 밝은 기존
/// 시스템 화면 위에 뜰 때 시각적으로 분리된다. 직사광선 대응은 라이트 테마가
/// 아니라 명도 대비를 최대로 두는 것으로 한다.
abstract final class RapidColors {
  static const carbon = Color(0xFF0B0F14); // 배경 최하단
  static const graphite = Color(0xFF151C24); // 카드 / 서페이스
  static const graphite2 = Color(0xFF1C2530); // 카드 위 요소
  static const line = Color(0xFF2A3542); // 구분선 · 보더
  static const paper = Color(0xFFEDEFF1); // 주 텍스트
  static const fog = Color(0xFF7C8894); // 보조 텍스트

  /// 녹음 중 · 경고 · 위급. 이중 용도는 의도 — 둘 다 "지금 주목" 신호다.
  static const siren = Color(0xFFFF4D5E);
  static const sirenDim = Color(0xFF4A2229);

  /// 확인 · 정상 · 주 액션. 녹색 = go.
  static const vital = Color(0xFF33D690);
  static const vitalDim = Color(0xFF173626);

  /// AI 소견 — 참고용이라는 표시.
  static const amber = Color(0xFFFFB454);
  static const amberDim = Color(0xFF3A2E15);
}

abstract final class RapidSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

abstract final class RapidRadius {
  static const card = 16.0;
  static const button = 14.0;

  /// 캡슐은 완전 둥글게.
  static const capsule = 999.0;
}

abstract final class RapidSize {
  /// 장갑 낀 손 기준. Material 기본 48dp보다 크게 잡는다.
  static const minTouchTarget = 56.0;
}

abstract final class RapidFont {
  static const body = 'Pretendard';

  /// 타이머·녹음 길이처럼 자리수가 흔들리면 안 되는 숫자용.
  static const mono = 'JetBrainsMono';
}

ThemeData buildRapidTheme() {
  const scheme = ColorScheme.dark(
    surface: RapidColors.carbon,
    onSurface: RapidColors.paper,
    surfaceContainer: RapidColors.graphite,
    surfaceContainerHigh: RapidColors.graphite2,
    outline: RapidColors.line,
    primary: RapidColors.vital,
    onPrimary: Color(0xFF062015),
    error: RapidColors.siren,
    onError: RapidColors.paper,
    tertiary: RapidColors.amber,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: RapidColors.carbon,
    fontFamily: RapidFont.body,
    dividerTheme: const DividerThemeData(color: RapidColors.line, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(RapidSize.minTouchTarget),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RapidRadius.button),
        ),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(RapidSize.minTouchTarget),
        foregroundColor: RapidColors.paper,
        side: const BorderSide(color: RapidColors.line),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RapidRadius.button),
        ),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
      ),
    ),
  );
}
