import 'dart:async';

import 'package:flutter/services.dart';

import '../model/analysis_result.dart';
import 'assistant_controller.dart';

/// 기기 없이 화면과 흐름을 검증하기 위한 구현.
///
/// 안드로이드 태블릿을 연결하기 전까지 앱 전체를 데스크톱에서 돌려보는 것이
/// 목적이다. 오버레이·포그라운드 서비스·마이크·카메라를 전부 메모리와 타이머로
/// 흉내 내고, 분석은 고정된 뇌졸중 시나리오를 돌려준다.
///
/// 실제 Gemini 호출은 여기 없다 — 3단계에서 백엔드를 붙일 때 별도 구현으로
/// 교체한다.
class FakeAssistantController implements AssistantController {
  FakeAssistantController({this.analysisDelay = const Duration(seconds: 3)});

  /// 분석 중 화면을 눈으로 확인할 수 있을 만큼의 지연.
  final Duration analysisDelay;

  final _controller = StreamController<AssistantState>.broadcast();
  var _state = const AssistantState();

  Timer? _recordTicker;
  Timer? _analysisTimer;

  /// 준비 항목을 일부러 부족한 상태로 두어 경고 블록을 볼 수 있게 한다.
  /// `requestReadiness()`를 부르면 전부 충족된 것으로 바꾼다.
  var _pending = {ReadinessItem.overlay, ReadinessItem.battery};

  // 앱 창 안에 캡슐을 그려 흉내 낸다 — 진짜 OS 오버레이가 아니다.
  @override
  bool get hasSystemOverlay => false;

  @override
  Future<void> collapse() async {}

  @override
  Stream<AssistantState> get states => _controller.stream;

  @override
  AssistantState get state => _state;

  void _emit(AssistantState next) {
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  @override
  Future<Set<ReadinessItem>> checkReadiness() async => _pending;

  @override
  Future<Set<ReadinessItem>> requestReadiness() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _pending = {};
    return _pending;
  }

  @override
  Future<void> startService() async {
    if (_pending.isNotEmpty) return;
    _emit(_state.copyWith(serviceRunning: true));
  }

  @override
  Future<void> stopService() async {
    _recordTicker?.cancel();
    _analysisTimer?.cancel();
    _emit(const AssistantState());
  }

  @override
  Future<void> toggleRecording() async {
    if (!_state.serviceRunning) return;

    if (_state.recording) {
      _recordTicker?.cancel();
      _emit(_state.copyWith(recording: false, hasRecording: true));
      return;
    }

    // 새 녹음 = 새 케이스. 이전 사진과 결과를 버린다.
    _analysisTimer?.cancel();
    _emit(_state.copyWith(
      recording: true,
      recordedSeconds: 0,
      hasRecording: false,
      photoPaths: const [],
      analyzing: false,
      clearResult: true,
      clearError: true,
    ));
    _recordTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      _emit(_state.copyWith(recordedSeconds: _state.recordedSeconds + 1));
    });
  }

  @override
  Future<void> discardRecording() async {
    _recordTicker?.cancel();
    _emit(_state.copyWith(
      recording: false,
      hasRecording: false,
      recordedSeconds: 0,
      photoPaths: const [],
      clearResult: true,
      clearError: true,
    ));
  }

  @override
  Future<void> addPhoto() async {
    if (_state.photoCount >= 3) return;
    // 실제 파일이 없으므로 빈 경로를 넣는다 — 화면은 자리 표시 아이콘으로 떨어진다.
    _emit(_state.copyWith(photoPaths: [..._state.photoPaths, '']));
  }

  @override
  Future<void> removePhoto(int index) async {
    if (index < 0 || index >= _state.photoPaths.length) return;
    _emit(_state.copyWith(
      photoPaths: [..._state.photoPaths]..removeAt(index),
    ));
  }

  @override
  Future<void> analyze(ConsentChoice consent) async {
    if (!_state.canAnalyze) return;

    // 스펙 06절 — 동의 불가 시 온디바이스 경로. 이번 범위에선 분석하지 않는다.
    if (consent == ConsentChoice.denied) {
      _emit(_state.copyWith(error: '온디바이스 분석은 준비 중입니다.'));
      return;
    }

    _emit(_state.copyWith(analyzing: true, clearResult: true, clearError: true));
    _analysisTimer = Timer(analysisDelay, () {
      _emit(_state.copyWith(analyzing: false, result: _strokeScenario));
    });
  }

  @override
  Future<void> cancelAnalysis() async {
    _analysisTimer?.cancel();
    _emit(_state.copyWith(analyzing: false));
  }

  @override
  void updateResult(AnalysisResult result) {
    _emit(_state.copyWith(result: result));
  }

  @override
  Future<void> copyToClipboard(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  @override
  void dispose() {
    _recordTicker?.cancel();
    _analysisTimer?.cancel();
    _controller.close();
  }
}

/// 기획안 01절의 뇌졸중 시나리오. 용어 수준(원문+괄호 병기 / 질환군명 /
/// 평이한 근거)을 실제 프롬프트 결과와 같게 맞춰 두어야 화면 검증이 의미 있다.
const _strokeScenario = AnalysisResult(
  chiefComplaint: '오른쪽이 안 움직이고 말이 어눌함 (우측 편마비·구음장애 의심)',
  pastHistory: '고혈압, OO병원 통원 중',
  onset: '오늘 07:20 (가족 발견)',
  lastNormalTime: '어제 23:00 (취침 전 정상)',
  guardian: '배우자 동승',
  etc: '항응고제 복용 이력 없음',
  aiImpression: '급성 뇌졸중 의심',
  reasons: [
    '편측(우측) 마비 + 발음 장애 — 국소 신경학적 결손 패턴과 일치',
    '수면 중 발생 추정 — 각성 시 이미 증상 있음, 급성 발병',
    '고혈압 병력 — 뇌혈관 질환 위험 인자와 부합',
  ],
);
