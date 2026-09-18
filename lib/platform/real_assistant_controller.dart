import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
// 생명주기 관찰(WidgetsBindingObserver)에 필요하다. debugPrint도 여기 포함된다.
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:record/record.dart';

import '../model/analysis_result.dart';
import 'assistant_controller.dart';
import 'overlay_protocol.dart';
import 'recording_service.dart';

/// 안드로이드 실구현 — 시스템 오버레이 캡슐 + 포그라운드 서비스.
///
/// 이 클래스는 상태를 **소유하지 않는다.** 녹음·분석·결과는 포그라운드 서비스가
/// 소유하고(스펙 00절), 여기서는 명령을 보내고 브로드캐스트된 상태를 화면용으로
/// 비춰 주기만 한다. 본앱이 죽었다 살아나도 서비스가 진실의 원천이므로 상태가
/// 복구된다.
///
/// 예외가 하나 있다 — 카메라 촬영은 액티비티가 필요해서 본앱에서 하고, 찍은
/// 경로만 서비스로 넘긴다.
class RealAssistantController
    with WidgetsBindingObserver
    implements AssistantController {
  RealAssistantController({required this.apiBaseUrl});

  /// 서비스 isolate는 본앱의 컴파일 타임 상수를 볼 수 없어, 시작할 때 저장해
  /// 넘겨 준다.
  final String apiBaseUrl;

  final _picker = ImagePicker();
  final _controller = StreamController<AssistantState>.broadcast();
  var _state = const AssistantState();

  /// 본앱에서 찍은 사진. 서비스에도 경로를 넘기지만, 촬영 직후 화면을 즉시
  /// 갱신하려고 여기에도 들고 있는다.
  final List<File> _photos = [];

  /// 캡슐을 닫기 전 위치. 다시 띄울 때 같은 자리로 돌려놓는다.
  OverlayPosition? _lastOverlayPosition;

  /// 캡슐 표시 전환이 겹쳐 실행되는 것을 막는다.
  bool _overlayBusy = false;

  @override
  bool get hasSystemOverlay => true;

  /// 캡슐이 화면 위에 그대로 남아 있으므로, 접는다는 것은 앱 창을
  /// 내리는 것이다(스펙 07절 — 축소해도 녹음·분석은 서비스에서 계속된다).
  @override
  Future<void> collapse() async =>
      FlutterForegroundTask.minimizeApp();

  @override
  Stream<AssistantState> get states => _controller.stream;

  @override
  AssistantState get state => _state;

  void _emit(AssistantState next) {
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  /// 앱 시작 시 한 번 불러 통신 포트와 알림 설정을 준비한다.
  Future<void> init() async {
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'rapid_assistant',
        channelName: 'RAPID 어시스턴트',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // 녹음 경과 시간을 캡슐에 흘려보내는 주기.
        eventAction: ForegroundTaskEventAction.repeat(1000),
        allowWakeLock: true,
        autoRunOnBoot: false,
      ),
    );
    FlutterForegroundTask.addTaskDataCallback(_onServiceData);
    WidgetsBinding.instance.addObserver(this);

    // 앱이 죽었다 다시 열린 경우 — 서비스가 아직 돌고 있으면 상태를 맞춘다.
    if (await FlutterForegroundTask.isRunningService) {
      _emit(_state.copyWith(serviceRunning: true));
      // 서비스는 상태가 바뀔 때만 알려 준다. 지금 상태를 한 번 달라고 청한다.
      FlutterForegroundTask.sendDataToTask(cmd(kCmdRequestState));
      await _setOverlayVisible(false);
    }
  }

  /// 앱이 전면에 있는 동안에는 캡슐을 띄우지 않는다. 캡슐은 119 화면 위에
  /// 떠 있으라고 만든 것인데, 우리 작업 화면 위에까지 겹쳐 보이면 방해만 된다.
  /// 축소·홈 버튼·앱 전환 등 어느 경로로 물러나도 같게 처리되도록 생명주기로
  /// 판단한다.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_state.serviceRunning) return;

    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_setOverlayVisible(false));
        // 전면으로 올라온 시점의 실제 상태를 서비스에서 다시 받아 온다.
        FlutterForegroundTask.sendDataToTask(cmd(kCmdRequestState));
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(_setOverlayVisible(true));
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// 캡슐 창을 띄우거나 닫는다.
  ///
  /// 플러그인에 "숨기기"가 없어 닫고 다시 띄우는 수밖에 없다. 그러면 대원이
  /// 옮겨 둔 위치를 잃으므로, 닫기 전에 좌표를 읽어 두고 다시 띄울 때 넘긴다.
  Future<void> _setOverlayVisible(bool visible) async {
    if (_overlayBusy) return;
    _overlayBusy = true;
    try {
      final active = await FlutterOverlayWindow.isActive();
      if (visible == active) return;

      if (!visible) {
        try {
          _lastOverlayPosition = await FlutterOverlayWindow.getOverlayPosition();
        } catch (_) {
          // 위치를 못 읽어도 닫는 것이 우선이다.
        }
        await FlutterOverlayWindow.closeOverlay();
        return;
      }

      // showOverlay()의 width/height는 dp가 아니라 그대로 픽셀로 쓰인다
      // (플러그인 버그 — resizeOverlay()만 dp 변환을 한다). 460을 dp로 알고
      // 넘겼더니 밀도 높은 기기(S25)에서 실제 폭이 훨씬 좁게 생성돼 녹음
      // 배지가 화면 밖으로 잘려 나갔다. 화면 폭(물리 픽셀) 안에 넉넉히
      // 들어가는 raw 픽셀 값을 바로 넘긴다.
      await FlutterOverlayWindow.showOverlay(
        height: 140,
        width: 700,
        alignment: OverlayAlignment.centerRight,
        flag: OverlayFlag.defaultFlag,
        enableDrag: true,
        positionGravity: PositionGravity.auto,
        overlayTitle: 'RAPID 캡슐',
        startPosition: _lastOverlayPosition,
      );
    } catch (e) {
      debugPrint('[RAPID] 캡슐 표시 전환 실패: $e');
    } finally {
      _overlayBusy = false;
    }
  }

  /// 서비스가 보낸 상태 브로드캐스트를 화면용 스냅샷으로 옮긴다.
  void _onServiceData(Object data) {
    if (data is! Map || data[kState] != true) return;

    final rawResult = data[kResult];
    final result = rawResult is Map
        ? AnalysisResult.fromJson(
            rawResult.map((k, v) => MapEntry(k.toString(), v)),
          )
        : null;

    final paths = ((data[kPhotoPaths] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(growable: false);

    _emit(AssistantState(
      serviceRunning: true,
      recording: data[kRecording] == true,
      recordedSeconds: (data[kElapsedSec] as num?)?.toInt() ?? 0,
      hasRecording: data[kHasRecording] == true,
      photoPaths: paths,
      analyzing: data[kAnalyzing] == true,
      result: result,
      error: data[kError] as String?,
    ));
  }

  @override
  Future<Set<ReadinessItem>> checkReadiness() async {
    final missing = <ReadinessItem>{};

    final mic = await AudioRecorder().hasPermission(request: false);
    if (!mic) missing.add(ReadinessItem.microphone);

    // record 패키지는 카메라 권한을 안 다뤄서 permission_handler로 따로 본다.
    // 이게 빠져 있던 탓에 "시작"에서 카메라 권한이 한 번도 요청되지 않았었다.
    final camera = await ph.Permission.camera.status.isGranted;
    if (!camera) missing.add(ReadinessItem.camera);

    final overlay = await FlutterOverlayWindow.isPermissionGranted();
    if (!overlay) missing.add(ReadinessItem.overlay);

    // 삼성 One UI는 배터리 절약으로 백그라운드 서비스를 죽인다. 예외로 빼지
    // 않으면 캡슐이 현장에서 조용히 사라진다.
    final battery = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!battery) missing.add(ReadinessItem.battery);

    // 진단용 — "권한 허용해도 시작 안 됨" 원인 조사. 어느 항목이 false로
    // 잡히는지가 핵심 증거라 Phase 4에서 지운다.
    debugPrint('[RAPID] checkReadiness: mic=$mic camera=$camera '
        'overlay=$overlay battery=$battery');
    return missing;
  }

  @override
  Future<Set<ReadinessItem>> requestReadiness() async {
    // 마이크·카메라는 표준 런타임 권한 다이얼로그로 받는다.
    await AudioRecorder().hasPermission();
    await ph.Permission.camera.request();
    await FlutterForegroundTask.requestNotificationPermission();

    // 오버레이는 필수라 결과를 기다린다. OS 특성상 인앱 다이얼로그가 불가능해
    // 설정 화면으로 보내야 한다.
    if (!await FlutterOverlayWindow.isPermissionGranted()) {
      await FlutterOverlayWindow.requestPermission();
    }

    // 배터리는 선택 사항이라 기다리지 않고 던지기만 한다. 직전 오버레이 설정
    // 화면 왕복과 연달아 activity 결과를 기다리면 콜백이 꼬여 이 await가
    // 영영 안 풀릴 수 있었다 — 그러면 배터리를 막지 않기로 한 의미가
    // 없어진다(여기서 멈추면 이후 항목 확인도 못 간다). 결과는 다음에
    // checkReadiness()가 다시 불릴 때 반영된다.
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      unawaited(FlutterForegroundTask.requestIgnoreBatteryOptimization());
    }
    return checkReadiness();
  }

  @override
  Future<void> startService() async {
    // 필수 항목만 막는다 — 배터리(blocking=false)는 거부돼도 시작한다.
    if ((await checkReadiness()).any((item) => item.blocking)) return;

    // 서비스 isolate가 읽을 수 있도록 먼저 저장한다.
    await FlutterForegroundTask.saveData(key: kApiBaseUrl, value: apiBaseUrl);

    final result = await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.microphone],
      notificationTitle: 'RAPID 실행 중',
      notificationText: '어시스턴트가 켜져 있습니다',
      notificationButtons: [const NotificationButton(id: 'stop', text: '중지')],
      callback: recordingServiceCallback,
    );
    if (result is ServiceRequestFailure) {
      _emit(_state.copyWith(error: '서비스를 시작할 수 없습니다: ${result.error}'));
      return;
    }

    _emit(_state.copyWith(serviceRunning: true, clearError: true));

    // 스펙 02절 — 시작하면 앱은 물러나고 119 화면이 다시 전면에 온다.
    // 캡슐은 여기서 직접 띄우지 않는다. 앱이 물러나는 순간 생명주기 관찰이
    // 띄워 주므로, 그 한 경로로만 관리해 중복·누락을 없앤다.
    //
    // 서비스 시작 직후 곧바로 최소화하면(특히 안드로이드16 삼성 기기) 런처의
    // 최근앱 갱신과 겹쳐 태스크가 "제거"로 처리되어 stopWithTask 때문에 방금
    // 켠 서비스가 같이 죽는 게 S25에서 확인됐다. 서비스 등록이 완전히
    // 끝난 뒤로 최소화를 미뤄 그 경합을 피한다.
    await Future.delayed(const Duration(milliseconds: 400));
    FlutterForegroundTask.minimizeApp();
  }

  @override
  Future<void> stopService() async {
    await FlutterOverlayWindow.closeOverlay();
    await FlutterForegroundTask.stopService();
    _photos.clear();
    _emit(const AssistantState());
  }

  @override
  Future<void> toggleRecording() async {
    _photos.clear();
    FlutterForegroundTask.sendDataToTask(cmd(kCmdToggleRecord));
  }

  @override
  Future<void> discardRecording() async {
    _photos.clear();
    FlutterForegroundTask.sendDataToTask(cmd(kCmdDiscardRecording));
  }

  /// 스펙 05절 — 카메라 촬영만. 갤러리는 열지 않는다.
  /// 촬영은 액티비티가 필요하므로 서비스가 아니라 여기서 한다.
  @override
  Future<void> addPhoto() async {
    if (_photos.length >= 3) return;

    final XFile? shot;
    try {
      shot = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        maxWidth: 1600,
        imageQuality: 85,
      );
    } on PlatformException catch (e) {
      _emit(_state.copyWith(error: '카메라를 열 수 없습니다: ${e.message}'));
      return;
    }
    if (shot == null) return; // 대원이 취소함 — 오류가 아니다.

    _photos.add(File(shot.path));
    _syncPhotos();
  }

  @override
  Future<void> removePhoto(int index) async {
    if (index < 0 || index >= _photos.length) return;
    final file = _photos.removeAt(index);
    try {
      if (file.existsSync()) await file.delete();
    } catch (e) {
      debugPrint('[RAPID] 사진 삭제 실패: $e');
    }
    _syncPhotos();
  }

  /// 사진 목록을 서비스에 넘기고, 화면은 즉시 갱신한다.
  /// (서비스 브로드캐스트를 기다리면 썸네일이 한 박자 늦게 뜬다.)
  void _syncPhotos() {
    final paths = _photos.map((f) => f.path).toList(growable: false);
    FlutterForegroundTask.sendDataToTask(cmd(kCmdSetPhotos, {kPhotos: paths}));
    _emit(_state.copyWith(photoPaths: paths, clearError: true));
  }

  @override
  Future<void> analyze(ConsentChoice consent) async {
    FlutterForegroundTask.sendDataToTask(
      cmd(kCmdAnalyze, {kConsent: consent.name}),
    );
  }

  @override
  Future<void> cancelAnalysis() async {
    FlutterForegroundTask.sendDataToTask(cmd(kCmdCancelAnalysis));
  }

  @override
  void updateResult(AnalysisResult result) {
    // 화면은 즉시 반영하고(편집 중 끊김 방지), 서비스에도 알려 진실의 원천을
    // 맞춘다.
    _emit(_state.copyWith(result: result));
    FlutterForegroundTask.sendDataToTask(
      cmd(kCmdUpdateResult, {kResult: result.toJson()}),
    );
  }

  @override
  Future<void> copyToClipboard(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FlutterForegroundTask.removeTaskDataCallback(_onServiceData);
    _controller.close();
  }
}
