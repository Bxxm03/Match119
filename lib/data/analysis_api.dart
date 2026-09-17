import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../model/analysis_result.dart';

/// 분석 실패를 화면에 보여줄 수 있는 형태로 감싼다.
class AnalysisException implements Exception {
  AnalysisException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 백엔드 프록시(`POST /api/analyze`)를 부른다.
///
/// Gemini API 키가 클라이언트에 실리면 안 되므로 앱은 언제나 우리 백엔드를
/// 거친다. 백엔드가 오디오+사진을 멀티모달 한 번의 호출로 Gemini에 넘기고
/// 구조화 JSON을 돌려준다(별도 STT 단계 없음).
class AnalysisApi {
  AnalysisApi({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  /// 개발 중에는 로컬 서버, 배포 시에는 Cloud Run 주소가 된다.
  final String baseUrl;
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

  /// 오디오(필수)와 사진(최대 3장)을 보내 구조화 결과를 받는다.
  Future<AnalysisResult> analyze({
    required File audio,
    List<File> photos = const [],
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/analyze'),
    );

    request.files.add(await http.MultipartFile.fromPath('audio', audio.path));
    for (final photo in photos.take(3)) {
      request.files.add(await http.MultipartFile.fromPath('photo', photo.path));
    }

    final http.Response res;
    try {
      // 멀티모달 분석은 수십 초가 걸릴 수 있다. 백엔드 자체 타임아웃보다
      // 넉넉하게 두어, 서버가 돌려주는 이유 있는 에러를 받을 수 있게 한다.
      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 90));
      res = await http.Response.fromStream(streamed);
    } on SocketException {
      throw AnalysisException('분석 서버에 연결할 수 없습니다.');
    } catch (e) {
      throw AnalysisException('분석 요청이 실패했습니다: $e');
    }

    if (res.statusCode != 200) {
      throw AnalysisException(_readableError(res));
    }

    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw AnalysisException('분석 결과 형식이 올바르지 않습니다.');
      }
      return AnalysisResult.fromJson(decoded);
    } on FormatException {
      throw AnalysisException('분석 결과를 읽을 수 없습니다.');
    }
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

    if (detail.contains('GEMINI_API_KEY')) {
      return '서버에 API 키가 설정되지 않았습니다.';
    }
    if (detail.contains('시간 초과')) {
      return '분석 시간이 초과되었습니다. 다시 시도해주세요.';
    }
    return '분석에 실패했습니다. (${res.statusCode})';
  }

  void dispose() => _client.close();
}
