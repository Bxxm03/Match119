import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapid_app/main.dart';
import 'package:rapid_app/platform/fake_assistant_controller.dart';

/// 스펙 01절 전체 흐름을 화면 단위로 훑는다.
/// 컨트롤 패널 → 캡슐 → 패널 → 동의 게이트 → 분석중 → 결과 → 복사.
void main() {
  /// 클립보드는 플랫폼 채널이라 테스트 환경에서 가로채야 한다.
  late List<String> copied;

  setUp(() {
    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<FakeAssistantController> pump(WidgetTester tester) async {
    final c = FakeAssistantController(
      analysisDelay: const Duration(milliseconds: 50),
    );
    await tester.pumpWidget(RapidApp(controller: c));
    await tester.pumpAndSettle();
    return c;
  }

  /// 준비 항목이 부족한 상태에서 "시작"을 누르면 요청 후 기동된다.
  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, '시작'));
    await tester.pumpAndSettle();
  }

  testWidgets('컨트롤 패널이 먼저 뜨고 부족한 준비 항목을 경고한다', (tester) async {
    await pump(tester);

    expect(find.text('RAPID'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '시작'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '가이드'), findsOneWidget);
    // Fake는 오버레이·배터리를 부족한 상태로 시작한다.
    expect(find.textContaining('필요합니다'), findsNWidgets(2));
  });

  testWidgets('시작하면 캡슐이 뜨고 중지하면 컨트롤 패널로 돌아온다', (tester) async {
    await pump(tester);
    await start(tester);

    // 축소 상태 — 캡슐만 보인다.
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    expect(find.byIcon(Icons.open_in_full_rounded), findsOneWidget);
    expect(find.textContaining('기존 119 시스템 화면'), findsOneWidget);
  });

  testWidgets('캡슐 마이크를 누르면 녹음 배지가 나타난다', (tester) async {
    await pump(tester);
    await start(tester);

    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pump(const Duration(seconds: 2));

    // 정지 아이콘으로 바뀌고 경과 시간이 표시된다.
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    expect(find.textContaining('0:0'), findsOneWidget);
  });

  testWidgets('녹음이 없으면 패널에서 분석하기가 비활성이다', (tester) async {
    await pump(tester);
    await start(tester);

    await tester.tap(find.byIcon(Icons.open_in_full_rounded));
    await tester.pumpAndSettle();

    expect(find.text('녹음 없음'), findsOneWidget);
    expect(find.textContaining('캡슐의 마이크를 눌러'), findsOneWidget);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '분석하기'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('녹음 → 확대 → 분석 → 동의(예) → 결과까지 간다', (tester) async {
    await pump(tester);
    await start(tester);

    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.open_in_full_rounded));
    await tester.pumpAndSettle();
    expect(find.textContaining('녹음됨'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '분석하기'));
    await tester.pumpAndSettle();

    // 동의 게이트 — 전체화면, 기본 선택 없음.
    expect(find.text('환자의 동의를 받으셨나요?'), findsOneWidget);
    expect(find.text('예'), findsOneWidget);
    expect(find.text('아니오'), findsOneWidget);

    await tester.tap(find.text('예'));
    await tester.pumpAndSettle();

    expect(find.text('결과 확인'), findsOneWidget);
    expect(find.text('주증상'), findsOneWidget);

    // AI 소견 카드는 6필드 아래에 있어 좁은 뷰포트에서는 화면 밖이다.
    // ListView가 보이는 것만 만들기 때문에 스크롤해야 트리에 올라온다.
    await tester.scrollUntilVisible(
      find.text('AI 종합소견 · 참고용'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    expect(find.text('AI 종합소견 · 참고용'), findsOneWidget);
    expect(find.text('급성 뇌졸중 의심'), findsOneWidget);
  });

  testWidgets('동의(아니오)면 분석하지 않고 안내만 띄운다', (tester) async {
    await pump(tester);
    await start(tester);

    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.open_in_full_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '분석하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('아니오'));
    await tester.pumpAndSettle();

    expect(find.text('결과 확인'), findsNothing);
    expect(find.textContaining('온디바이스'), findsOneWidget);
  });

  group('결과 화면 종결 액션', () {
    /// 결과 화면까지 밀어 넣는다.
    Future<void> toResult(WidgetTester tester) async {
      await pump(tester);
      await start(tester);
      await tester.tap(find.byIcon(Icons.mic_rounded));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byIcon(Icons.stop_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.open_in_full_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '분석하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('예'));
      await tester.pumpAndSettle();
    }

    testWidgets('"복사"는 소견·근거를 포함하고 자동 축소된다', (tester) async {
      await toResult(tester);

      await tester.tap(find.widgetWithText(FilledButton, '복사'));
      await tester.pump();

      expect(copied, hasLength(1));
      expect(copied.single, contains('AI 의심소견: 급성 뇌졸중 의심'));
      expect(copied.single, contains('근거:'));
      expect(copied.single, contains('(우측 편마비·구음장애 의심)'));

      await tester.pumpAndSettle(const Duration(seconds: 2));
      // 캡슐로 돌아왔다.
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    });

    testWidgets('"사실만 남기기"는 소견·근거를 빼고 괄호도 지운다', (tester) async {
      await toResult(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, '사실만 남기기'));
      await tester.pump();

      expect(copied, hasLength(1));
      expect(copied.single, isNot(contains('AI 의심소견')));
      expect(copied.single, isNot(contains('근거:')));
      expect(copied.single, isNot(contains('(우측 편마비·구음장애 의심)')));
      expect(copied.single, contains('주증상: 오른쪽이 안 움직이고 말이 어눌함'));
    });

    testWidgets('편집 토글로 필드를 고치면 복사 결과에 반영된다', (tester) async {
      await toResult(tester);

      await tester.tap(find.widgetWithText(TextButton, '편집'));
      await tester.pumpAndSettle();

      // 보호자 필드를 찾아 값을 바꾼다.
      final guardianField = find.ancestor(
        of: find.text('보호자'),
        matching: find.byType(Column),
      );
      expect(guardianField, findsWidgets);

      await tester.enterText(find.byType(TextFormField).at(4), '보호자 없음');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, '완료'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, '복사'));
      await tester.pump();

      expect(copied.single, contains('보호자: 보호자 없음'));
    });
  });

  testWidgets('분석 중 "이전"은 분석을 취소하고 패널로 돌아간다', (tester) async {
    final c = await pump(tester);
    await start(tester);

    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.open_in_full_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '분석하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('예'));
    await tester.pump();

    expect(find.textContaining('분석하는 중'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '이전'));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(c.state.result, isNull);
    expect(find.widgetWithText(FilledButton, '분석하기'), findsOneWidget);
  });

  testWidgets('사진은 3장까지만 추가된다', (tester) async {
    await pump(tester);
    await start(tester);

    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.open_in_full_rounded));
    await tester.pumpAndSettle();

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
    }

    expect(find.text('사진 (3/3)'), findsOneWidget);
    // 3장이 되면 추가 타일이 사라진다.
    expect(find.byIcon(Icons.add), findsNothing);
  });
}
