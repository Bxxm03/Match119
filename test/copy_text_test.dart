import 'package:flutter_test/flutter_test.dart';
import 'package:rapid_app/logic/copy_text.dart';
import 'package:rapid_app/model/analysis_result.dart';

/// 스펙 09절 예시를 그대로 쓴다 — 기획안의 뇌졸중 시나리오.
const _sample = AnalysisResult(
  chiefComplaint: '오른쪽이 안 움직이고 말이 어눌함 (우측 편마비·구음장애 의심)',
  pastHistory: '고혈압, OO병원 통원 중',
  onset: '오늘 07:20 (가족 발견)',
  lastNormalTime: '어제 23:00 (취침 전 정상)',
  guardian: '배우자 동승',
  etc: '항응고제 복용 이력 없음',
  aiImpression: '급성 뇌졸중 의심',
  reasons: ['편측(우측) 마비 + 발음 장애', '수면 중 발생 추정', '고혈압 병력'],
);

void main() {
  group('AnalysisResult.fromJson', () {
    test('6필드 + 소견 + 근거를 파싱한다', () {
      final r = AnalysisResult.fromJson({
        'chief_complaint': '가슴이 답답함 (흉통 의심)',
        'past_history': '당뇨',
        'onset': '30분 전',
        'last_normal_time': '1시간 전',
        'guardian': '없음',
        'etc': '',
        'ai_impression': '급성 심근경색 의심',
        'reasons': ['흉통 호소', '식은땀'],
      });

      expect(r.chiefComplaint, '가슴이 답답함 (흉통 의심)');
      expect(r.pastHistory, '당뇨');
      expect(r.etc, '');
      expect(r.aiImpression, '급성 심근경색 의심');
      expect(r.reasons, ['흉통 호소', '식은땀']);
    });

    test('키가 없거나 null이면 빈 문자열로 둔다', () {
      final r = AnalysisResult.fromJson({'chief_complaint': null});
      expect(r.chiefComplaint, '');
      expect(r.guardian, '');
      expect(r.reasons, isEmpty);
    });

    test('reasons가 리스트가 아니면 빈 리스트로 둔다', () {
      expect(AnalysisResult.fromJson({'reasons': '문자열'}).reasons, isEmpty);
      expect(AnalysisResult.fromJson({'reasons': null}).reasons, isEmpty);
    });

    test('reasons의 빈 항목은 버린다', () {
      final r = AnalysisResult.fromJson({
        'reasons': ['근거1', '', '  ', '근거2'],
      });
      expect(r.reasons, ['근거1', '근거2']);
    });
  });

  group('CopyText.withImpression ("복사" — AI 판단 맞음)', () {
    test('기타 줄 바로 다음에 소견과 근거가 붙는다', () {
      final lines = CopyText.withImpression(_sample).split('\n');

      expect(lines, [
        '주증상: 오른쪽이 안 움직이고 말이 어눌함 (우측 편마비·구음장애 의심)',
        '과거력(F/U병원): 고혈압, OO병원 통원 중',
        '발병시점(onset): 오늘 07:20 (가족 발견)',
        '마지막정상확인시간(LNT): 어제 23:00 (취침 전 정상)',
        '보호자: 배우자 동승',
        '기타: 항응고제 복용 이력 없음',
        'AI 의심소견: 급성 뇌졸중 의심',
        '근거: 편측(우측) 마비 + 발음 장애; 수면 중 발생 추정; 고혈압 병력',
      ]);
    });

    test('주증상의 괄호 의학용어는 그대로 남긴다', () {
      expect(CopyText.withImpression(_sample), contains('(우측 편마비·구음장애 의심)'));
    });

    test('소견이 비어 있으면 그 줄을 넣지 않는다', () {
      const r = AnalysisResult(chiefComplaint: '복통', etc: '특이사항 없음');
      final text = CopyText.withImpression(r);
      expect(text, isNot(contains('AI 의심소견')));
      expect(text, isNot(contains('근거:')));
      expect(text.split('\n').length, ResultField.values.length);
    });
  });

  group('CopyText.factsOnly ("사실만 남기기" — AI 판단 틀림)', () {
    test('6필드만 남고 소견·근거는 둘 다 빠진다', () {
      final text = CopyText.factsOnly(_sample);
      expect(text.split('\n').length, ResultField.values.length);
      expect(text, isNot(contains('AI 의심소견')));
      expect(text, isNot(contains('근거:')));
      expect(text, isNot(contains('급성 뇌졸중')));
    });

    test('주증상의 괄호 의학용어를 걷어내고 원문 표현만 남긴다', () {
      final first = CopyText.factsOnly(_sample).split('\n').first;
      expect(first, '주증상: 오른쪽이 안 움직이고 말이 어눌함');
    });

    test('주증상 외 필드의 괄호는 건드리지 않는다', () {
      final text = CopyText.factsOnly(_sample);
      expect(text, contains('발병시점(onset): 오늘 07:20 (가족 발견)'));
      expect(text, contains('마지막정상확인시간(LNT): 어제 23:00 (취침 전 정상)'));
    });
  });

  group('CopyText.stripMedicalTerms', () {
    test('괄호가 여러 개면 전부 제거한다', () {
      expect(
        CopyText.stripMedicalTerms('오른쪽 마비 (편마비) 와 어눌함 (구음장애)'),
        '오른쪽 마비 와 어눌함',
      );
    });

    test('괄호가 없으면 그대로 둔다', () {
      expect(CopyText.stripMedicalTerms('배가 아픔'), '배가 아픔');
    });

    test('빈 문자열도 안전하다', () {
      expect(CopyText.stripMedicalTerms(''), '');
    });
  });

  group('ResultField', () {
    test('라벨 순서가 기존 시스템 서식과 같다', () {
      expect(
        ResultField.values.map((f) => f.label),
        ['주증상', '과거력(F/U병원)', '발병시점(onset)', '마지막정상확인시간(LNT)', '보호자', '기타'],
      );
    });

    test('apply로 해당 필드만 바뀐다', () {
      final edited = ResultField.guardian.apply(_sample, '보호자 없음');
      expect(edited.guardian, '보호자 없음');
      expect(edited.chiefComplaint, _sample.chiefComplaint);
      expect(edited.aiImpression, _sample.aiImpression);
    });
  });
}
