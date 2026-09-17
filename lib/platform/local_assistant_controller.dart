import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../data/analysis_api.dart';
import '../model/analysis_result.dart';
import 'assistant_controller.dart';

/// 실제 마이크로 녹음하고, 실제 카메라로 촬영하고, 실제 백엔드(→ Gemini)로
/// 분석하는 구현.
///
/// 오버레이와 포그라운드 서비스는 아직 붙이지 않았다 — 그 둘은 안드로이드
/// 기기에서만 검증할 수 있으므로 별도 단계로 미뤘다. 그 둘을 빼면 나머지는
/// 전부 진짜라서 "녹음 → 촬영 → 분석 → 결과 → 복사" 전체가 실제로 돈다.
/// `record`는 Windows도 지원하므로 개발 노트북에서도 녹음·분석은 동작한다
/// (카메라는 기기에서만).
class LocalAssistantController implements AssistantController {
  LocalAssistantController({required this.api});

  final AnalysisApi api;

  final _recorder = AudioRecorder();
  final _picker = ImagePicker();
  final _controller = StreamController<AssistantState>.broadcast();
  var _state = const AssistantState();

  Timer? _ticker;
  File? _audioFile;

  /// 촬영한 사진. 스펙 05절대로 최대 3장.
  final List<File> _photos = [];

  /// 취소를 눌렀을 때 뒤늦게 도착한 결과를 무시하기 위한 표식.
  int _analysisGeneration = 0;

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
  Future<Set<ReadinessItem>> checkReadiness() async {
    final missing = <ReadinessItem>{};
    if (!await _recorder.hasPermission(request: false)) {
      missing.add(ReadinessItem.microphone);
    }
    return missing;
  }

  @override
  Future<Set<ReadinessItem>> requestReadiness() async {
    final missing = <ReadinessItem>{};
    // record가 직접 권한을 요청한다. 오버레이·배터리는 안드로이드 전용이라
    // 4단계에서 여기에 추가된다.
    if (!await _recorder.hasPermission()) {
      missing.add(ReadinessItem.microphone);
    }
    return missing;
  }

  @override
  Future<void> startService() async {
    // 필수 항목만 막는다 — 배터리(blocking=false)는 거부돼도 시작한다.
    if ((await checkReadiness()).any((item) => item.blocking)) return;
    _emit(_state.copyWith(serviceRunning: true));
  }

  @override
  Future<void> stopService() async {
    _ticker?.cancel();
    _analysisGeneration++;
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    await _deleteAudio();
    await _deletePhotos();
    _emit(const AssistantState());
  }

  @override
  Future<void> toggleRecording() async {
    if (!_state.serviceRunning) return;

    if (_state.recording) {
      _ticker?.cancel();
      final path = await _recorder.stop();
      _audioFile = path == null ? null : File(path);
      final ok = _audioFile?.existsSync() ?? false;
      _emit(_state.copyWith(recording: false, hasRecording: ok));
      if (!ok) {
        _emit(_state.copyWith(error: '녹음 파일을 만들지 못했습니다.'));
      }
      return;
    }

    if (!await _recorder.hasPermission()) {
      _emit(_state.copyWith(error: '마이크 권한이 필요합니다.'));
      return;
    }

    // 새 녹음 = 새 케이스. 이전 오디오·사진·결과를 모두 버린다.
    _analysisGeneration++;
    await _deleteAudio();
    await _deletePhotos();

    final dir = await getApplicationDocumentsDirectory();
    final path =
        '${dir.path}/rapid_${DateTime.now().millisecondsSinceEpoch}.m4a';

    try {
      // 기본 인코더가 AAC다. WAV는 파일이 10배 커져서 불안정한 구급차
      // 네트워크로 올리기에 불리하다.
      await _recorder.start(const RecordConfig(), path: path);
    } catch (e) {
      _emit(_state.copyWith(error: '녹음을 시작할 수 없습니다: $e'));
      return;
    }

    _emit(_state.copyWith(
      recording: true,
      recordedSeconds: 0,
      hasRecording: false,
      photoPaths: const [],
      analyzing: false,
      clearResult: true,
      clearError: true,
    ));

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _emit(_state.copyWith(recordedSeconds: _state.recordedSeconds + 1));
    });
  }

  @override
  Future<void> discardRecording() async {
    _ticker?.cancel();
    _analysisGeneration++;
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    await _deleteAudio();
    await _deletePhotos();
    _emit(_state.copyWith(
      recording: false,
      hasRecording: false,
      recordedSeconds: 0,
      photoPaths: const [],
      clearResult: true,
      clearError: true,
    ));
  }

  /// 스펙 05절 — 카메라 촬영만 지원한다. 갤러리는 열지 않는다.
  /// 응급 현장에서 실시간으로 찍는 것이 전제라 과거 사진을 쓸 일이 없고,
  /// 갤러리를 열면 환자와 무관한 사진이 섞여 들어갈 위험만 생긴다.
  @override
  Future<void> addPhoto() async {
    if (_photos.length >= 3) return;

    final XFile? shot;
    try {
      shot = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        // 상처·환자 상태를 판독할 정도면 충분하다. 원본 해상도는 업로드만
        // 무겁게 만든다(불안정한 현장 네트워크를 고려).
        maxWidth: 1600,
        imageQuality: 85,
      );
    } on PlatformException catch (e) {
      _emit(_state.copyWith(error: '카메라를 열 수 없습니다: ${e.message}'));
      return;
    }

    // 대원이 촬영을 취소한 경우 — 오류가 아니다.
    if (shot == null) return;

    _photos.add(File(shot.path));
    _emit(_state.copyWith(photoPaths: _pathsOf(_photos), clearError: true));
  }

  @override
  Future<void> removePhoto(int index) async {
    if (index < 0 || index >= _photos.length) return;
    final file = _photos.removeAt(index);
    await _deleteFile(file);
    _emit(_state.copyWith(photoPaths: _pathsOf(_photos)));
  }

  @override
  Future<void> analyze(ConsentChoice consent) async {
    if (!_state.canAnalyze) return;

    if (consent == ConsentChoice.denied) {
      _emit(_state.copyWith(error: '온디바이스 분석은 준비 중입니다.'));
      return;
    }

    final audio = _audioFile;
    if (audio == null || !audio.existsSync()) {
      _emit(_state.copyWith(error: '녹음 파일을 찾을 수 없습니다.'));
      return;
    }

    final generation = ++_analysisGeneration;
    _emit(_state.copyWith(analyzing: true, clearResult: true, clearError: true));

    try {
      final result = await api.analyze(audio: audio, photos: List.of(_photos));
      // 분석 중에 취소하거나 새 녹음을 시작했으면 결과를 버린다.
      if (generation != _analysisGeneration) return;
      _emit(_state.copyWith(analyzing: false, result: result));
    } on AnalysisException catch (e) {
      if (generation != _analysisGeneration) return;
      _emit(_state.copyWith(analyzing: false, error: e.message));
    } catch (e) {
      if (generation != _analysisGeneration) return;
      debugPrint('[RAPID] 분석 실패: $e');
      _emit(_state.copyWith(analyzing: false, error: '분석에 실패했습니다.'));
    }
  }

  @override
  Future<void> cancelAnalysis() async {
    // 세대를 올려 진행 중인 응답을 무효화한다. 요청 자체는 서버에서 끝나지만
    // 결과를 화면에 반영하지 않는다.
    _analysisGeneration++;
    _emit(_state.copyWith(analyzing: false));
  }

  @override
  void updateResult(AnalysisResult result) {
    _emit(_state.copyWith(result: result));
  }

  @override
  Future<void> copyToClipboard(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  /// 환자 음성이 기기에 남지 않도록 쓰고 나면 지운다.
  Future<void> _deleteAudio() async {
    final file = _audioFile;
    _audioFile = null;
    await _deleteFile(file);
  }

  /// 환자 사진도 음성과 같은 이유로 기기에 남기지 않는다.
  /// image_picker는 촬영본을 앱 캐시에 복사해 두므로 우리가 지워야 한다.
  Future<void> _deletePhotos() async {
    final files = List.of(_photos);
    _photos.clear();
    for (final file in files) {
      await _deleteFile(file);
    }
  }

  List<String> _pathsOf(List<File> files) =>
      files.map((f) => f.path).toList(growable: false);

  Future<void> _deleteFile(File? file) async {
    if (file == null) return;
    try {
      if (file.existsSync()) await file.delete();
    } catch (e) {
      debugPrint('[RAPID] 파일 삭제 실패(${file.path}): $e');
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _recorder.dispose();
    api.dispose();
    _controller.close();
  }
}
