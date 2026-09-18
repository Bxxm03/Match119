import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../data/analysis_api.dart';
import '../model/analysis_result.dart';
import 'assistant_controller.dart';
import 'overlay_protocol.dart';

/// 포그라운드 서비스 isolate 진입점. 최상위 함수여야 한다.
@pragma('vm:entry-point')
void recordingServiceCallback() {
  FlutterForegroundTask.setTaskHandler(RecordingTaskHandler());
}

/// 스펙 00절 "상태의 주인 = 포그라운드 서비스"의 실제 구현.
///
/// 녹음기와 진행 상태를 여기서만 소유한다. 본앱 화면과 캡슐 오버레이는 이 상태를
/// 비추고 명령만 보낸다. 본앱이 죽어도 서비스가 살아 있으므로, 대원이 화면을
/// 축소한 뒤에도 녹음과 분석이 계속된다(스펙 07절).
///
/// 사진 촬영만 예외다 — 카메라는 액티비티가 필요해서 본앱에서 찍고, 경로만
/// 이쪽으로 넘겨받는다.
class RecordingTaskHandler extends TaskHandler {
  final AudioRecorder _recorder = AudioRecorder();

  AnalysisApi? _api;
  StreamSubscription<dynamic>? _overlaySub;
  Timer? _ticker;

  bool _recording = false;
  bool _hasRecording = false;
  bool _analyzing = false;
  int _elapsed = 0;
  File? _audioFile;
  List<String> _photoPaths = const [];
  AnalysisResult? _result;
  String? _error;

  /// 취소 후 뒤늦게 도착한 응답을 버리기 위한 표식.
  int _analysisGeneration = 0;

  void _log(String message) => debugPrint('[RAPID:service] $message');

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _log('시작 (starter=${starter.name})');

    // 서비스는 본앱의 컴파일 타임 상수를 볼 수 없으므로, 시작할 때 저장해 둔
    // 주소를 읽어 온다.
    final baseUrl = await FlutterForegroundTask.getData<String>(key: kApiBaseUrl);
    _api = AnalysisApi(baseUrl: baseUrl ?? 'http://127.0.0.1:8000');

    // 캡슐이 보내는 명령을 직접 받는다. 본앱이 죽어 있어도 캡슐의 마이크 버튼이
    // 동작해야 하므로, 본앱을 경유하지 않는 이 경로가 있어야 한다.
    try {
      _overlaySub = FlutterOverlayWindow.overlayListener.listen(_onOverlayData);
      _log('오버레이 리스너 구독됨');
    } catch (e) {
      _log('오버레이 리스너 구독 실패: $e');
    }

    _broadcast();
  }

  /// 녹음 경과 시간을 캡슐에 흘려보내는 통로. `ForegroundTaskOptions`의
  /// 반복 주기에 맞춰 호출된다.
  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_recording) {
      _elapsed++;
      _broadcast();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _log('종료 (timeout=$isTimeout)');
    _ticker?.cancel();
    await _overlaySub?.cancel();
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    await _recorder.dispose();
    await _deleteAudio();
    await _deletePhotos();
    _api?.dispose();
  }

  /// 본앱이 보내는 명령.
  @override
  void onReceiveData(Object data) {
    if (data is Map) _handle(data);
  }

  /// 알림의 "중지" 버튼. 스펙 03절 — 앱을 열지 않고도 끌 수 있어야 한다.
  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') {
      FlutterOverlayWindow.closeOverlay();
      FlutterForegroundTask.stopService();
    }
  }

  /// 캡슐이 보내는 명령.
  void _onOverlayData(dynamic data) {
    if (data is Map && data[kCmd] != null) _handle(data);
  }

  void _handle(Map<dynamic, dynamic> data) {
    switch (data[kCmd]) {
      case kCmdToggleRecord:
        unawaited(_toggleRecording());
      case kCmdExpand:
        // 캡슐의 확대 버튼 — 본앱 액티비티를 전면으로 올린다.
        // SYSTEM_ALERT_WINDOW 권한이 있어야 동작한다.
        FlutterForegroundTask.launchApp();
      case kCmdSetPhotos:
        _photoPaths = ((data[kPhotos] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false);
        _broadcast();
      case kCmdAnalyze:
        final consent = data[kConsent] == ConsentChoice.granted.name
            ? ConsentChoice.granted
            : ConsentChoice.denied;
        unawaited(_analyze(consent));
      case kCmdRequestState:
        _broadcast();
      case kCmdCancelAnalysis:
        _analysisGeneration++;
        _analyzing = false;
        _broadcast();
      case kCmdDiscardRecording:
        unawaited(_discardRecording());
      case kCmdUpdateResult:
        final raw = data[kResult];
        if (raw is Map) {
          _result = AnalysisResult.fromJson(
            raw.map((k, v) => MapEntry(k.toString(), v)),
          );
          _broadcast();
        }
    }
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      final path = await _recorder.stop();
      _recording = false;
      _audioFile = path == null ? null : File(path);
      _hasRecording = _audioFile?.existsSync() ?? false;
      if (!_hasRecording) _error = '녹음 파일을 만들지 못했습니다.';
      _log('녹음 정지 ($_elapsed초, path=$path)');
      _broadcast();
      return;
    }

    // hasPermission()을 여기서 다시 묻지 않는다 — 서비스가 시작되기 전에
    // 메인 앱이 이미 확인했다(checkReadiness의 블로킹 항목). Service(Activity
    // 없는) isolate에서 이 호출이 false를 돌려줘 녹음이 조용히 실패했었다 —
    // 캡슐 쪽엔 에러를 보여줄 화면이 없어 증상이 "탭해도 무반응"으로만 보였다.
    // 정말 권한이 없다면 아래 start()가 실패하고, 그 실패는 catch에서 잡는다.

    // 새 녹음 = 새 케이스. 이전 오디오·사진·결과를 모두 버린다.
    _analysisGeneration++;
    await _deleteAudio();
    await _deletePhotos();

    final dir = await getApplicationDocumentsDirectory();
    final path =
        '${dir.path}/rapid_${DateTime.now().millisecondsSinceEpoch}.m4a';

    try {
      // 기본 인코더가 AAC다. WAV는 파일이 10배 커져 불안정한 구급차 네트워크로
      // 올리기에 불리하다.
      await _recorder.start(const RecordConfig(), path: path);
    } catch (e) {
      _error = '녹음을 시작할 수 없습니다: $e';
      _broadcast();
      return;
    }

    _recording = true;
    _hasRecording = false;
    _analyzing = false;
    _elapsed = 0;
    _result = null;
    _error = null;
    _log('녹음 시작 -> $path');
    _broadcast();
  }

  Future<void> _discardRecording() async {
    _analysisGeneration++;
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    await _deleteAudio();
    await _deletePhotos();
    _recording = false;
    _hasRecording = false;
    _elapsed = 0;
    _result = null;
    _error = null;
    _broadcast();
  }

  Future<void> _analyze(ConsentChoice consent) async {
    if (!_hasRecording || _analyzing) return;

    // 스펙 06절 — 동의를 받을 수 없으면 온디바이스 경로. 이번 범위에서는
    // 실제 분석을 하지 않는다.
    if (consent == ConsentChoice.denied) {
      _error = '온디바이스 분석은 준비 중입니다.';
      _broadcast();
      return;
    }

    final audio = _audioFile;
    if (audio == null || !audio.existsSync()) {
      _error = '녹음 파일을 찾을 수 없습니다.';
      _broadcast();
      return;
    }

    final generation = ++_analysisGeneration;
    _analyzing = true;
    _result = null;
    _error = null;
    _broadcast();

    try {
      final result = await _api!.analyze(
        audio: audio,
        photos: _photoPaths.map(File.new).where((f) => f.existsSync()).toList(),
        durationSeconds: _elapsed,
      );
      if (generation != _analysisGeneration) return;
      _analyzing = false;
      _result = result;
      _log('분석 완료');
    } on AnalysisException catch (e) {
      if (generation != _analysisGeneration) return;
      _analyzing = false;
      _error = e.message;
    } catch (e) {
      if (generation != _analysisGeneration) return;
      _analyzing = false;
      _error = '분석에 실패했습니다.';
      _log('분석 실패: $e');
    }
    _broadcast();
  }

  /// 상태를 본앱과 캡슐 양쪽에 보낸다.
  void _broadcast() {
    final payload = <String, Object?>{
      kState: true,
      kRecording: _recording,
      kElapsedSec: _elapsed,
      kHasRecording: _hasRecording,
      kAnalyzing: _analyzing,
      kPhotoPaths: _photoPaths,
      kResult: _result?.toJson(),
      kError: _error,
    };

    FlutterForegroundTask.sendDataToMain(payload);
    try {
      FlutterOverlayWindow.shareData(payload);
    } catch (e) {
      _log('캡슐로 상태 전송 실패: $e');
    }

    // 에러는 한 번 알린 뒤 비운다 — 같은 메시지가 계속 다시 뜨면 안 된다.
    _error = null;
  }

  /// 환자 음성이 기기에 남지 않도록 쓰고 나면 지운다.
  Future<void> _deleteAudio() async {
    final file = _audioFile;
    _audioFile = null;
    _hasRecording = false;
    if (file == null) return;
    try {
      if (file.existsSync()) await file.delete();
    } catch (e) {
      _log('녹음 파일 삭제 실패: $e');
    }
  }

  /// 환자 사진도 같은 이유로 남기지 않는다.
  Future<void> _deletePhotos() async {
    final paths = _photoPaths;
    _photoPaths = const [];
    for (final path in paths) {
      try {
        final file = File(path);
        if (file.existsSync()) await file.delete();
      } catch (e) {
        _log('사진 삭제 실패($path): $e');
      }
    }
  }
}
