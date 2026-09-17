import '../model/analysis_result.dart';

/// 스펙 08·09절 — 결과를 기존 시스템 텍스트박스에 붙여넣을 형태로 만든다.
///
/// 종결 액션이 두 개이고 둘의 차이가 전부 여기에 있다:
/// - [withImpression] : AI 판단이 맞다고 대원이 확인한 경우
/// - [factsOnly]      : AI 판단이 틀렸다고 대원이 확인한 경우
abstract final class CopyText {
  /// "복사" — 6필드 + `기타` 줄 뒤에 AI 의심소견·근거를 덧붙인다.
  ///
  /// 기존 시스템엔 소견을 위한 별도 필드가 없어서 `기타` 끝에 얹는 방식으로
  /// 전달한다(스펙 08절 고정 안내문과 같은 내용).
  static String withImpression(AnalysisResult r) {
    final lines = <String>[];
    for (final f in ResultField.values) {
      lines.add('${f.label}: ${f.valueOf(r)}');
      if (f == ResultField.etc) {
        if (r.aiImpression.isNotEmpty) {
          lines.add('AI 의심소견: ${r.aiImpression}');
        }
        if (r.reasons.isNotEmpty) {
          lines.add('근거: ${r.reasons.join('; ')}');
        }
      }
    }
    return lines.join('\n');
  }

  /// "사실만 남기기" — 6필드만. 의심소견과 근거를 **둘 다** 뺀다.
  ///
  /// 근거를 왜 같이 빼는가: 근거는 소견을 뒷받침하는 용도라, 소견이 없으면
  /// 근거만 남아도 의미가 없고 오히려 대원을 혼란스럽게 한다. 원칙 03
  /// (AI 출력은 참고정보)의 안전장치를 여기서 구현한다.
  ///
  /// 주증상의 괄호 의학용어도 제거한다 — AI 해석이 틀렸다고 판단한 상황이므로
  /// AI가 붙인 의학용어는 남기지 않고 대화 원문 표현만 남긴다.
  static String factsOnly(AnalysisResult r) {
    final lines = <String>[];
    for (final f in ResultField.values) {
      final raw = f.valueOf(r);
      final value =
          f == ResultField.chiefComplaint ? stripMedicalTerms(raw) : raw;
      lines.add('${f.label}: $value');
    }
    return lines.join('\n');
  }

  /// 괄호로 병기된 의학용어를 걷어낸다.
  ///
  /// 파일럿의 정규식엔 `g` 플래그가 없어 첫 괄호만 지워졌다(스펙 09절에
  /// "의도 여부 확인 필요"로 남아 있던 부분). 괄호가 두 개 이상인 주증상이
  /// 나올 수 있고 일부만 지우면 결과가 어정쩡해지므로 전부 제거로 확정한다.
  static String stripMedicalTerms(String value) =>
      value.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();
}
