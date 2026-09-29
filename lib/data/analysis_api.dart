import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../model/analysis_result.dart';

/// 분석 실패를 화면에 보여줄 수 있는 형태로 감싼다.
class AnalysisException implements Exception {
  AnalysisException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 이보다 짧은 녹음은 올리지도 분석하지도 않는다. 서버 `MIN_AUDIO_SECONDS`와
/// 같은 값 — 잡음만 담긴 녹음으로 모델이 가짜 응급상황을 지어내는 것을 막고,
/// 애초에 환자 음성을 서버로 보내지 않는다.
const minAudioSeconds = 2;

/// 서버가 받는 사진 최대 장수(스펙 05절).
const maxPhotos = 3;

/// URL 발급·업로드·분석을 합친 전체 제한 시간. 기존 multipart 방식도 업로드와
/// 분석을 합쳐 90초였다. 서버 분석 예산(75초, 정리 포함 최악 86초)보다 길게 둔다.
const _totalTimeout = Duration(seconds: 90);

/// 녹음기가 항상 AAC(.m4a)로 녹음한다.
const _audioMime = 'audio/mp4';

const _msgConnect = '분석 서버에 연결할 수 없습니다.';
const _msgTimeout = '분석 시간이 초과되었습니다. 다시 시도해주세요.';
const _msgUpload = '파일 업로드에 실패했습니다. 네트워크를 확인 후 다시 시도해주세요.';
const _msgBadResponse = '분석 결과를 읽을 수 없습니다.';

/// 백엔드(Cloud Run)를 거쳐 분석한다.
///
/// 1. `POST /api/uploads` — 분석 직전에 PUT용 Signed URL을 받는다(10분 뒤 만료).
/// 2. 오디오·사진을 Cloud Storage에 직접 PUT한다(서버가 준 헤더 그대로).
/// 3. `POST /api/analyze` — 객체 이름을 넘기면 서버가 Vertex AI(Gemini)에
///    gs:// 주소로 전달하고 구조화 JSON을 돌려준다. 원본은 서버가 곧바로 지운다.
///
/// 모델 호출 권한은 서버에만 있으므로 앱은 언제나 우리 백엔드를 거친다.
class AnalysisApi {
  AnalysisApi({required this.baseUrl, this.token = '', http.Client? client})
      : _client = client ?? http.Client();

  /// 개발 중에는 로컬 서버, 배포 시에는 Cloud Run 주소가 된다.
  final String baseUrl;

  /// 백엔드 `APP_TOKEN`과 같은 공유 토큰(`X-RAPID-Token`). 무단 호출 방지용
  /// 최소 보호일 뿐 보안 인증이 아니다. 값은 로그에 남기지 않는다.
  final String token;
  final http.Client _client;

  /// 앱이 백엔드를 찾았는지 확인한다.
  Future<bool> health() async {
    try {
      final res = await _client
          .get(Uri.parse('$baseUrl/api/health'))
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 오디오(필수)와 사진(최대 3장)을 올려 구조화 결과를 받는다.
  Future<AnalysisResult> analyze({
    required File audio,
    List<File> photos = const [],
    int durationSeconds = 0,
  }) async {
    if (durationSeconds < minAudioSeconds) {
      debugPrint('[RAPID] 녹음 $durationSeconds초 — 너무 짧아 업로드·분석을 생략한다');
      return const AnalysisResult();
    }
    if (token.isEmpty) {
      debugPrint('[RAPID] 경고: RAPID_TOKEN이 설정되지 않았다');
    }

    final deadline = DateTime.now().add(_totalTimeout);
    try {
      return await _run(
        audio,
        photos.take(maxPhotos).toList(growable: false),
        durationSeconds,
        deadline,
      );
    } on AnalysisException {
      rethrow;
    } on TimeoutException {
      throw AnalysisException(_msgTimeout);
    } on SocketException {
      throw AnalysisException(_msgConnect);
    } on http.ClientException {
      throw AnalysisException(_msgConnect);
    } on FormatException {
      throw AnalysisException(_msgBadResponse);
    } catch (e) {
      // 예외 문구에 Signed URL(서명값 포함)이 섞일 수 있어 종류만 남긴다.
      debugPrint('[RAPID] 분석 요청 실패: ${e.runtimeType}');
      throw AnalysisException('분석에 실패했습니다.');
    }
  }

  Future<AnalysisResult> _run(
    File audio,
    List<File> photos,
    int durationSeconds,
    DateTime deadline,
  ) async {
    final photoMimes = [for (final p in photos) await _photoMime(p)];

    // 1. 업로드 주소 발급 — URL이 10분 뒤 만료되므로 분석 직전에 받는다.
    final uploads = await _postJson(
      '/api/uploads',
      {'audio_mime': _audioMime, 'photo_mimes': photoMimes},
      deadline,
    );
    final sessionId = uploads['session_id'];
    final audioTarget = _UploadTarget.fromJson(uploads['audio']);
    final rawPhotos = uploads['photos'];
    if (sessionId is! String ||
        rawPhotos is! List ||
        rawPhotos.length != photos.length) {
      throw const FormatException('업로드 주소 응답 형식 오류');
    }
    final photoTargets =
        rawPhotos.map(_UploadTarget.fromJson).toList(growable: false);

    // 2. Cloud Storage에 직접 PUT. 걸린 시간은 발표 수치용으로 서버에 넘긴다.
    final watch = Stopwatch()..start();
    await Future.wait([
      _put(audioTarget, audio, deadline),
      for (var i = 0; i < photos.length; i++)
        _put(photoTargets[i], photos[i], deadline),
    ]);
    final uploadMs = watch.elapsedMilliseconds;

    // 3. 분석 요청 — 남은 시간만 쓴다.
    final result = await _postJson(
      '/api/analyze',
      {
        'session_id': sessionId,
        'audio_object': audioTarget.object,
        'photo_objects': [for (final t in photoTargets) t.object],
        'duration_seconds': durationSeconds,
        'client_upload_ms': uploadMs,
      },
      deadline,
    );
    return AnalysisResult.fromJson(result);
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, Object?> body,
    DateTime deadline,
  ) async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl$path'),
          headers: {
            'Content-Type': 'application/json',
            'X-RAPID-Token': token,
          },
          body: jsonEncode(body),
        )
        .timeout(_remaining(deadline));

    if (res.statusCode != 200) {
      throw AnalysisException(_readableError(res));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw AnalysisException('분석 결과 형식이 올바르지 않습니다.');
    }
    return decoded;
  }

  /// Signed URL로 파일 하나를 올린다. 실패하면 한 번만 다시 시도한다.
  ///
  /// 헤더(`Content-Type`, `x-goog-content-length-range`)는 서명에 포함돼 있어
  /// 서버가 준 값을 그대로 붙여야 한다. 그래서 `body`(문자열) 대신 `bodyBytes`를
  /// 쓴다 — `body`는 http 패키지가 Content-Type에 charset을 덧붙여 서명이 깨진다.
  Future<void> _put(_UploadTarget target, File file, DateTime deadline) async {
    final bytes = await file.readAsBytes();
    for (var attempt = 1;; attempt++) {
      final request = http.Request('PUT', Uri.parse(target.url))
        ..headers.addAll(target.headers)
        ..bodyBytes = bytes;

      int? status;
      try {
        final res = await _client.send(request).timeout(_remaining(deadline));
        await res.stream.drain<void>();
        status = res.statusCode;
        if (status >= 200 && status < 300) return;
        debugPrint('[RAPID] 업로드 실패(시도 $attempt): HTTP $status');
      } on TimeoutException {
        // 전체 제한 시간을 다 썼다 — 다시 시도할 시간이 없다.
        rethrow;
      } catch (e) {
        // Signed URL이 로그에 남지 않도록 예외 종류만 적는다.
        debugPrint('[RAPID] 업로드 실패(시도 $attempt): ${e.runtimeType}');
      }

      // 400/403은 서명·형식 불일치라 다시 보내도 같다.
      final retryable = status == null ||
          status >= 500 ||
          status == 408 ||
          status == 429;
      if (!retryable || attempt >= 2) {
        throw AnalysisException(_msgUpload);
      }
    }
  }

  /// 파일 앞 바이트로 실제 형식을 판별한다(확장자는 믿지 않는다).
  Future<String> _photoMime(File file) async {
    final head = <int>[];
    await for (final chunk in file.openRead(0, 4)) {
      head.addAll(chunk);
    }
    if (head.length >= 3 &&
        head[0] == 0xFF &&
        head[1] == 0xD8 &&
        head[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (head.length >= 4 &&
        head[0] == 0x89 &&
        head[1] == 0x50 &&
        head[2] == 0x4E &&
        head[3] == 0x47) {
      return 'image/png';
    }
    throw AnalysisException('지원하지 않는 사진 형식입니다.');
  }

  Duration _remaining(DateTime deadline) {
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) {
      throw TimeoutException('앱 전체 제한 시간 초과');
    }
    return left;
  }

  /// 백엔드는 실패 이유를 `detail`에 담아 보낸다. 대원에게는 원문 대신
  /// 짧은 문구를 보여 주고, 원문은 로그로만 남긴다.
  String _readableError(http.Response res) {
    var detail = res.body;
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map && decoded['detail'] != null) {
        detail = decoded['detail'].toString();
      }
    } catch (_) {
      // 본문이 JSON이 아니면 그대로 둔다.
    }
    debugPrint('[RAPID] 서버 오류 ${res.statusCode}: $detail');

    if (res.statusCode == 504 || detail.contains('시간 초과')) {
      return _msgTimeout;
    }
    return switch (res.statusCode) {
      401 => '앱 설정 오류로 분석 서버에 접속할 수 없습니다. 관리자에게 문의해주세요.',
      400 => '분석 요청이 올바르지 않습니다. 다시 녹음 후 시도해주세요.',
      502 => 'AI 분석에 일시적인 문제가 있습니다. 다시 시도해주세요.',
      _ => '분석에 실패했습니다. (${res.statusCode})',
    };
  }

  void dispose() => _client.close();
}

/// `/api/uploads` 응답의 파일 하나 — 객체 이름, PUT 주소, 붙일 헤더.
class _UploadTarget {
  const _UploadTarget(this.object, this.url, this.headers);

  final String object;
  final String url;
  final Map<String, String> headers;

  static _UploadTarget fromJson(Object? json) {
    if (json is! Map ||
        json['object'] is! String ||
        json['url'] is! String ||
        json['headers'] is! Map) {
      throw const FormatException('업로드 주소 응답 형식 오류');
    }
    return _UploadTarget(
      json['object'] as String,
      json['url'] as String,
      (json['headers'] as Map)
          .map((k, v) => MapEntry(k.toString(), v.toString())),
    );
  }
}
