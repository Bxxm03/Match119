/// 스펙 09절 — 백엔드가 돌려주는 분석 결과.
///
/// 용어 수준이 필드마다 다르다는 점이 이 스키마의 핵심이다:
/// - 기본 6필드는 대화 원문 표현 + 의학용어 괄호 병기 (오역 시 원문 대조로 드러남)
/// - [aiImpression]은 대원이 현장에서 쓰는 질환군명 수준까지만
/// - [reasons]는 항상 평이한 관찰언어 — 대원의 검증은 "내가 보고 들은 것과
///   일치하는지" 확인하는 방식이라서
class AnalysisResult {
  const AnalysisResult({
    this.chiefComplaint = '',
    this.pastHistory = '',
    this.onset = '',
    this.lastNormalTime = '',
    this.guardian = '',
    this.etc = '',
    this.aiImpression = '',
    this.reasons = const [],
  });

  final String chiefComplaint;
  final String pastHistory;
  final String onset;
  final String lastNormalTime;
  final String guardian;
  final String etc;

  /// AI 의심 소견. 확정 진단이 아니다 — 대원 1차, 병원 의사 2차로 이중 검증된다.
  final String aiImpression;

  /// 소견의 근거. 관찰 언어만.
  final List<String> reasons;

  /// 대화에서 확인되지 않은 필드는 빈 문자열로 온다(백엔드 프롬프트 지시).
  /// 키가 아예 없거나 null인 경우도 같게 취급한다.
  factory AnalysisResult.fromJson(Map<String, dynamic> json) {
    String s(String key) => (json[key] as String?)?.trim() ?? '';
    return AnalysisResult(
      chiefComplaint: s('chief_complaint'),
      pastHistory: s('past_history'),
      onset: s('onset'),
      lastNormalTime: s('last_normal_time'),
      guardian: s('guardian'),
      etc: s('etc'),
      aiImpression: s('ai_impression'),
      reasons: switch (json['reasons']) {
        final List<dynamic> list => list
            .map((e) => e?.toString().trim() ?? '')
            .where((e) => e.isNotEmpty)
            .toList(growable: false),
        _ => const [],
      },
    );
  }

  Map<String, dynamic> toJson() => {
        'chief_complaint': chiefComplaint,
        'past_history': pastHistory,
        'onset': onset,
        'last_normal_time': lastNormalTime,
        'guardian': guardian,
        'etc': etc,
        'ai_impression': aiImpression,
        'reasons': reasons,
      };

  /// 결과 화면의 "편집" 토글에서 필드를 고칠 때 쓴다.
  AnalysisResult copyWith({
    String? chiefComplaint,
    String? pastHistory,
    String? onset,
    String? lastNormalTime,
    String? guardian,
    String? etc,
    String? aiImpression,
    List<String>? reasons,
  }) {
    return AnalysisResult(
      chiefComplaint: chiefComplaint ?? this.chiefComplaint,
      pastHistory: pastHistory ?? this.pastHistory,
      onset: onset ?? this.onset,
      lastNormalTime: lastNormalTime ?? this.lastNormalTime,
      guardian: guardian ?? this.guardian,
      etc: etc ?? this.etc,
      aiImpression: aiImpression ?? this.aiImpression,
      reasons: reasons ?? this.reasons,
    );
  }
}

/// 결과 화면이 6필드를 표시·편집할 때 쓰는 식별자.
/// 라벨 문자열은 기존 시스템 화면과 동일해야 하므로 여기에 묶어 둔다.
enum ResultField {
  chiefComplaint('주증상'),
  pastHistory('과거력(F/U병원)'),
  onset('발병시점(onset)'),
  lastNormalTime('마지막정상확인시간(LNT)'),
  guardian('보호자'),
  etc('기타');

  const ResultField(this.label);

  /// 기존 시스템 텍스트박스에 찍히는 라벨. 바꾸면 대원이 붙여넣은 결과가
  /// 기존 서식과 안 맞게 되므로 임의로 수정하지 말 것.
  final String label;

  String valueOf(AnalysisResult r) => switch (this) {
        ResultField.chiefComplaint => r.chiefComplaint,
        ResultField.pastHistory => r.pastHistory,
        ResultField.onset => r.onset,
        ResultField.lastNormalTime => r.lastNormalTime,
        ResultField.guardian => r.guardian,
        ResultField.etc => r.etc,
      };

  AnalysisResult apply(AnalysisResult r, String value) => switch (this) {
        ResultField.chiefComplaint => r.copyWith(chiefComplaint: value),
        ResultField.pastHistory => r.copyWith(pastHistory: value),
        ResultField.onset => r.copyWith(onset: value),
        ResultField.lastNormalTime => r.copyWith(lastNormalTime: value),
        ResultField.guardian => r.copyWith(guardian: value),
        ResultField.etc => r.copyWith(etc: value),
      };
}
