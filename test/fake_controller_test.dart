import 'package:flutter_test/flutter_test.dart';
import 'package:rapid_app/platform/assistant_controller.dart';
import 'package:rapid_app/platform/fake_assistant_controller.dart';

/// Fake 구현이 스펙의 상태 전환 규칙을 지키는지 본다. Real 구현도 같은 규칙을
/// 따라야 하므로, 여기 적힌 기대값이 사실상 플랫폼 계층의 계약서다.
void main() {
  late FakeAssistantController c;

  setUp(() {
    c = FakeAssistantController(analysisDelay: const Duration(milliseconds: 10));
  });

  tearDown(() => c.dispose());

  Future<void> ready() async {
    await c.requestReadiness();
    await c.startService();
  }

  group('준비 상태', () {
    test('처음엔 오버레이·배터리가 부족하다', () async {
      expect(await c.checkReadiness(), {
        ReadinessItem.overlay,
        ReadinessItem.battery,
      });
    });

    test('요청하면 전부 충족된다', () async {
      expect(await c.requestReadiness(), isEmpty);
      expect(await c.checkReadiness(), isEmpty);
    });

    test('준비되지 않으면 서비스가 시작되지 않는다', () async {
      await c.startService();
      expect(c.state.serviceRunning, isFalse);
    });
  });

  group('녹음', () {
    test('서비스가 꺼져 있으면 녹음이 시작되지 않는다', () async {
      await c.toggleRecording();
      expect(c.state.recording, isFalse);
    });

    test('토글로 시작하고 멈추면 분석 가능 상태가 된다', () async {
      await ready();

      await c.toggleRecording();
      expect(c.state.recording, isTrue);
      expect(c.state.hasRecording, isFalse);
      expect(c.state.canAnalyze, isFalse);

      await c.toggleRecording();
      expect(c.state.recording, isFalse);
      expect(c.state.hasRecording, isTrue);
      expect(c.state.canAnalyze, isTrue);
    });

    test('새 녹음은 새 케이스 — 이전 사진과 결과를 버린다', () async {
      await ready();
      await c.toggleRecording();
      await c.toggleRecording();
      await c.addPhoto();
      await c.analyze(ConsentChoice.granted);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(c.state.result, isNotNull);
      expect(c.state.photoCount, 1);

      await c.toggleRecording();
      expect(c.state.result, isNull);
      expect(c.state.photoCount, 0);
      expect(c.state.recordedSeconds, 0);
    });

    test('녹음을 버리면 처음 상태로 돌아간다', () async {
      await ready();
      await c.toggleRecording();
      await c.toggleRecording();
      await c.discardRecording();

      expect(c.state.hasRecording, isFalse);
      expect(c.state.canAnalyze, isFalse);
      expect(c.state.recordedSeconds, 0);
    });
  });

  group('사진', () {
    test('최대 3장까지만 추가된다', () async {
      await ready();
      for (var i = 0; i < 5; i++) {
        await c.addPhoto();
      }
      expect(c.state.photoCount, 3);
    });

    test('0장에서 삭제해도 음수가 되지 않는다', () async {
      await ready();
      await c.removePhoto(0);
      expect(c.state.photoCount, 0);
    });
  });

  group('분석', () {
    test('녹음이 없으면 분석하지 않는다', () async {
      await ready();
      await c.analyze(ConsentChoice.granted);
      expect(c.state.analyzing, isFalse);
      expect(c.state.result, isNull);
    });

    test('동의를 받으면 결과가 나온다', () async {
      await ready();
      await c.toggleRecording();
      await c.toggleRecording();

      await c.analyze(ConsentChoice.granted);
      expect(c.state.analyzing, isTrue);
      expect(c.state.screen, AssistantScreen.analyzing);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(c.state.analyzing, isFalse);
      expect(c.state.result, isNotNull);
      expect(c.state.result!.aiImpression, isNotEmpty);
      expect(c.state.screen, AssistantScreen.result);
    });

    test('동의 불가면 분석하지 않고 안내만 남긴다', () async {
      await ready();
      await c.toggleRecording();
      await c.toggleRecording();

      await c.analyze(ConsentChoice.denied);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(c.state.analyzing, isFalse);
      expect(c.state.result, isNull);
      expect(c.state.error, contains('온디바이스'));
      expect(c.state.screen, AssistantScreen.panel);
    });

    test('취소하면 결과 없이 패널로 돌아간다', () async {
      await ready();
      await c.toggleRecording();
      await c.toggleRecording();
      await c.analyze(ConsentChoice.granted);
      await c.cancelAnalysis();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(c.state.analyzing, isFalse);
      expect(c.state.result, isNull);
      expect(c.state.screen, AssistantScreen.panel);
    });
  });

  group('화면 라우팅 (스펙 04절)', () {
    test('녹음이 없어도 패널을 막지 않는다', () async {
      await ready();
      expect(c.state.screen, AssistantScreen.panel);
    });

    test('결과가 있으면 결과 화면으로 간다', () async {
      await ready();
      await c.toggleRecording();
      await c.toggleRecording();
      await c.analyze(ConsentChoice.granted);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(c.state.screen, AssistantScreen.result);
    });

    test('분석 중이 결과보다 우선한다', () async {
      await ready();
      await c.toggleRecording();
      await c.toggleRecording();
      await c.analyze(ConsentChoice.granted);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await c.analyze(ConsentChoice.granted);
      expect(c.state.screen, AssistantScreen.analyzing);
    });
  });

  group('편집', () {
    test('수정한 결과가 반영된다', () async {
      await ready();
      await c.toggleRecording();
      await c.toggleRecording();
      await c.analyze(ConsentChoice.granted);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final edited = c.state.result!.copyWith(guardian: '보호자 없음');
      c.updateResult(edited);
      expect(c.state.result!.guardian, '보호자 없음');
    });
  });

  group('중지', () {
    test('모든 상태가 초기화된다', () async {
      await ready();
      await c.toggleRecording();
      await c.addPhoto();
      await c.stopService();

      expect(c.state.serviceRunning, isFalse);
      expect(c.state.recording, isFalse);
      expect(c.state.hasRecording, isFalse);
      expect(c.state.photoCount, 0);
      expect(c.state.result, isNull);
    });
  });
}
