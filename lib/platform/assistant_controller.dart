import 'dart:async';

import '../model/analysis_result.dart';

/// 스펙 01절 UI 상태. 화면 라우팅은 이 값 하나로 결정된다.
enum AssistantScreen { panel, analyzing, result }

/// 스펙 00절 "상태의 주인 = 포그라운드 서비스"를 앱 코드 쪽에서 본 모습.
///
/// 녹음·분석 상태는 앱이 아니라 플랫폼(안드로이드에선 포그라운드 서비스)이
/// 소유한다. 화면은 이 스냅샷을 그려 주고 명령만 내린다. 앱이 죽었다 살아나도
/// 플랫폼이 상태를 들고 있으므로 복구된다.
class AssistantState {
  const AssistantState({
    this.serviceRunning = false,
    this.recording = false,
    this.recordedSeconds = 0,
    this.hasRecording = false,
    this.photoPaths = const [],
    this.analyzing = false,
    this.result,
    this.error,
  });

  int get photoCount => photoPaths.length;

  final bool serviceRunning;
  final bool recording;
  final int recordedSeconds;

  /// 녹음이 끝나 분석에 쓸 오디오가 준비된 상태.
  final bool hasRecording;

  /// 촬영한 사진의 파일 경로. 썸네일을 그리려면 개수만으로는 부족하다.
  /// Fake 구현은 실제 파일이 없으므로 빈 문자열을 넣고, 화면은 파일을 못 읽으면
  /// 자리 표시 아이콘으로 떨어진다.
  final List<String> photoPaths;

  final bool analyzing;
  final AnalysisResult? result;
  final String? error;

  /// 스펙 04절 확대 라우팅 표. 녹음이 없어도 패널을 열고 막지 않는다 —
  /// "확대 = 항상 작업 화면 열기"로 예외를 없앴다.
  AssistantScreen get screen {
    if (analyzing) return AssistantScreen.analyzing;
    if (result != null) return AssistantScreen.result;
    return AssistantScreen.panel;
  }

  /// 스펙 05절 — 녹음이 없으면 "분석하기"를 누를 수 없다.
  bool get canAnalyze => hasRecording && !analyzing;

  AssistantState copyWith({
    bool? serviceRunning,
    bool? recording,
    int? recordedSeconds,
    bool? hasRecording,
    List<String>? photoPaths,
    bool? analyzing,
    AnalysisResult? result,
    bool clearResult = false,
    String? error,
    bool clearError = false,
  }) {
    return AssistantState(
      serviceRunning: serviceRunning ?? this.serviceRunning,
      recording: recording ?? this.recording,
      recordedSeconds: recordedSeconds ?? this.recordedSeconds,
      hasRecording: hasRecording ?? this.hasRecording,
      photoPaths: photoPaths ?? this.photoPaths,
      analyzing: analyzing ?? this.analyzing,
      result: clearResult ? null : (result ?? this.result),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// 환자 동의 여부 — 스펙 06절 동의 게이트의 결과.
///
/// 녹음 자체는 적법하고(본인 참여 대화) 문제가 되는 것은 제3자 AI 서버로의
/// 전송이므로, 이 선택은 전송 직전에 강제된다.
enum ConsentChoice {
  /// 동의 받음 → 클라우드 분석.
  granted,

  /// 동의 불가(의식불명, 보호자 부재) → 온디바이스 경로.
  /// 이번 범위에서는 실제 분석이 없다.
  denied,
}

/// 준비 상태 점검 항목 — 스펙 01절 "문제 있을 때" 경고 블록에 쓴다.
///
/// [battery]만 [blocking]이 false다. 삼성 One UI가 실제로 서비스를 죽이는지는
/// 아직 실측 전(체크리스트 7번)이고, 배터리 예외 요청 자체가 activity 콜백이
/// 얽혀 막힐 수 있다는 게 드러났다. 아직 검증도 안 된 가정 하나 때문에 훨씬
/// 중요한 것(캡슐↔서비스 통신)을 테스트조차 못 하는 게 더 큰 손해라, "시작"을
/// 막지 않는 권장 사항으로 낮춘다. 나중에 실측해서 정말 죽는 게 확인되면 다시
/// 막는 조건으로 올린다.
enum ReadinessItem {
  microphone('마이크', blocking: true),
  camera('카메라', blocking: true),
  overlay("'다른 앱 위에 표시' 권한", blocking: true),
  battery('배터리 제한 해제', blocking: false);

  const ReadinessItem(this.label, {required this.blocking});
  final String label;
  final bool blocking;
}

/// 플랫폼 경계. 화면 코드는 이 인터페이스만 본다.
///
/// 구현이 둘이다:
/// - `FakeAssistantController`  — 기기 없이 화면·흐름을 검증하기 위한 것
/// - `RealAssistantController`  — 오버레이 + 포그라운드 서비스 + 실제 녹음
///
/// 기기가 없는 동안에도 앱 전체를 돌려볼 수 있게 하려고 나눠 둔 것이다.
abstract interface class AssistantController {
  Stream<AssistantState> get states;
  AssistantState get state;

  /// 캡슐이 진짜 OS 오버레이로 떠 있는가.
  ///
  /// true면 앱 창 안에 캡슐을 그려선 안 된다 — 이미 화면 위에 떠 있으므로
  /// 두 개가 보이게 된다. 이때 "축소"는 앱 창을 내리는 동작이 된다.
  /// false(데스크톱·Fake)면 앱 창 안에 캡슐을 그려 흉내 낸다.
  bool get hasSystemOverlay;

  /// 작업 화면을 접는다. 시스템 오버레이가 있으면 앱을 백그라운드로 내리고,
  /// 없으면 아무것도 하지 않는다(화면 전환은 UI가 알아서 한다).
  Future<void> collapse();

  /// 아직 충족되지 않은 준비 항목. 비어 있으면 바로 시작할 수 있다.
  Future<Set<ReadinessItem>> checkReadiness();

  /// 부족한 항목을 요청한다(설정 화면으로 보내는 것 포함).
  /// 요청 후에도 남아 있는 항목을 돌려준다.
  Future<Set<ReadinessItem>> requestReadiness();

  /// 캡슐을 띄우고 서비스를 기동한다.
  Future<void> startService();

  /// 캡슐·서비스·알림을 모두 정리한다.
  Future<void> stopService();

  /// 캡슐 마이크 탭. 새 녹음을 시작하면 이전 사진·결과는 버린다
  /// (새 녹음 = 새 케이스).
  Future<void> toggleRecording();

  /// 녹음을 버리고 다시 녹음할 수 있게 한다.
  Future<void> discardRecording();

  /// 카메라로 촬영해 사진을 추가한다. 최대 3장.
  Future<void> addPhoto();

  Future<void> removePhoto(int index);

  /// 동의 결과에 따라 분석을 시작한다.
  /// [ConsentChoice.denied]면 이번 범위에서는 분석하지 않는다.
  Future<void> analyze(ConsentChoice consent);

  /// 진행 중인 분석을 취소한다. 화면을 축소하는 것과는 다르다 —
  /// 축소해도 분석은 계속된다(원칙 02: 처치를 방해하지 않는다).
  Future<void> cancelAnalysis();

  /// 편집 토글로 고친 내용을 반영한다.
  void updateResult(AnalysisResult result);

  /// 결과 텍스트를 OS 클립보드에 넣는다.
  Future<void> copyToClipboard(String text);

  void dispose();
}
