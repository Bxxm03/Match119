import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rapid_app/data/analysis_api.dart';

/// 새 분석 흐름(uploads → PUT → analyze)을 가짜 HTTP 클라이언트로 확인한다.
/// 실제 서버·버킷에는 닿지 않는다.
void main() {
  const base = 'http://test';
  const token = 'test-token';
  const sessionId = '0123456789abcdef0123456789abcdef';
  const audioObject = 'sessions/$sessionId/audio.m4a';
  const photoObject = 'sessions/$sessionId/photo-0.jpg';
  const audioHeaders = {
    'Content-Type': 'audio/mp4',
    'x-goog-content-length-range': '0,52428800',
  };

  late Directory dir;
  late File audio;
  late File jpeg;
  late File png;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('rapid_api_test');
    audio = File('${dir.path}/a.m4a')..writeAsBytesSync([0, 0, 0, 0x20, 1, 2]);
    jpeg = File('${dir.path}/p.jpg')..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0, 9]);
    // 확장자와 무관하게 내용으로 판별하는지 보려고 일부러 .jpg로 둔다.
    png = File('${dir.path}/q.jpg')
      ..writeAsBytesSync([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, Object?> uploadsBody(List<String> photoMimes) => {
        'session_id': sessionId,
        'expires_at': '2026-09-29T12:00:00+09:00',
        'audio': {
          'object': audioObject,
          'url': 'https://storage.test/audio?sig=x',
          'method': 'PUT',
          'headers': audioHeaders,
        },
        'photos': [
          for (var i = 0; i < photoMimes.length; i++)
            {
              'object': i == 0 ? photoObject : 'sessions/$sessionId/photo-$i.png',
              'url': 'https://storage.test/photo-$i?sig=x',
              'method': 'PUT',
              'headers': {
                'Content-Type': photoMimes[i],
                'x-goog-content-length-range': '0,10485760',
              },
            },
        ],
      };

  const analysisBody = {
    'chief_complaint': '가슴이 아파요(흉통)',
    'past_history': '',
    'onset': '',
    'last_normal_time': '',
    'guardian': '',
    'etc': '',
    'ai_impression': '심혈관계 질환 의심',
    'reasons': ['가슴 통증 호소'],
  };

  http.Response json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json'},
      );

  /// 요청을 기록하고, PUT 응답 코드는 [putStatuses] 순서대로 돌려준다.
  ({MockClient client, List<http.Request> calls}) fakeServer({
    List<int> putStatuses = const [],
    int uploadsStatus = 200,
    Object? uploadsError,
    int analyzeStatus = 200,
    Object? analyzeError,
  }) {
    final calls = <http.Request>[];
    var putIndex = 0;
    final client = MockClient((req) async {
      calls.add(req);
      if (req.method == 'PUT') {
        final status =
            putIndex < putStatuses.length ? putStatuses[putIndex] : 200;
        putIndex++;
        return http.Response('', status);
      }
      if (req.url.path == '/api/uploads') {
        if (uploadsStatus != 200) {
          return json(uploadsError ?? {'detail': '오류'}, uploadsStatus);
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        return json(uploadsBody(List<String>.from(body['photo_mimes'] as List)));
      }
      if (req.url.path == '/api/analyze') {
        if (analyzeStatus != 200) {
          return json(analyzeError ?? {'detail': '오류'}, analyzeStatus);
        }
        return json(analysisBody);
      }
      return http.Response('not found', 404);
    });
    return (client: client, calls: calls);
  }

  Future<String> failureMessage(Future<Object?> future) async {
    try {
      await future;
    } on AnalysisException catch (e) {
      return e.message;
    }
    fail('AnalysisException이 나야 한다');
  }

  test('성공 — uploads → PUT → analyze 순서로 부르고 결과를 파싱한다', () async {
    final server = fakeServer();
    final api = AnalysisApi(baseUrl: base, token: token, client: server.client);

    final result = await api.analyze(
      audio: audio,
      photos: [jpeg],
      durationSeconds: 47,
    );

    expect(result.chiefComplaint, '가슴이 아파요(흉통)');
    expect(result.reasons, ['가슴 통증 호소']);

    final calls = server.calls;
    expect(calls.map((c) => c.method).toList(), ['POST', 'PUT', 'PUT', 'POST']);
    expect(calls.first.url.path, '/api/uploads');
    expect(calls.last.url.path, '/api/analyze');

    // 서버 호출에는 토큰, Signed URL PUT에는 토큰을 싣지 않는다.
    expect(calls.first.headers['X-RAPID-Token'], token);
    expect(calls.last.headers['X-RAPID-Token'], token);
    for (final put in calls.where((c) => c.method == 'PUT')) {
      expect(put.headers.containsKey('X-RAPID-Token'), isFalse);
    }

    final uploadsReq = jsonDecode(calls.first.body) as Map<String, dynamic>;
    expect(uploadsReq['audio_mime'], 'audio/mp4');
    expect(uploadsReq['photo_mimes'], ['image/jpeg']);

    // 서명에 묶인 헤더를 변형 없이 그대로 붙인다(charset 덧붙임 없음).
    final audioPut = calls.firstWhere((c) => c.url.path == '/audio');
    expect(audioPut.headers['Content-Type'], 'audio/mp4');
    expect(audioPut.headers['x-goog-content-length-range'], '0,52428800');
    expect(audioPut.bodyBytes, audio.readAsBytesSync());

    final analyzeReq = jsonDecode(calls.last.body) as Map<String, dynamic>;
    expect(analyzeReq['session_id'], sessionId);
    expect(analyzeReq['audio_object'], audioObject);
    expect(analyzeReq['photo_objects'], [photoObject]);
    expect(analyzeReq['duration_seconds'], 47);
    expect(analyzeReq['client_upload_ms'], isA<int>());
  });

  test('사진 형식은 확장자가 아니라 파일 내용으로 정한다', () async {
    final server = fakeServer();
    final api = AnalysisApi(baseUrl: base, token: token, client: server.client);

    await api.analyze(audio: audio, photos: [jpeg, png], durationSeconds: 10);

    final uploadsReq = jsonDecode(server.calls.first.body) as Map<String, dynamic>;
    expect(uploadsReq['photo_mimes'], ['image/jpeg', 'image/png']);
    final pngPut = server.calls.firstWhere((c) => c.url.path == '/photo-1');
    expect(pngPut.headers['Content-Type'], 'image/png');
  });

  test('토큰 오류(401) — 설정 오류 문구, 업로드·분석은 하지 않는다', () async {
    final server = fakeServer(
      uploadsStatus: 401,
      uploadsError: {'detail': '인증 실패'},
    );
    final api = AnalysisApi(baseUrl: base, token: 'wrong', client: server.client);

    final message = await failureMessage(
      api.analyze(audio: audio, durationSeconds: 10),
    );

    expect(message, contains('앱 설정 오류'));
    expect(server.calls, hasLength(1));
  });

  test('PUT 실패 — 1회 재시도해서 성공하면 분석까지 진행한다', () async {
    final server = fakeServer(putStatuses: [503, 200]);
    final api = AnalysisApi(baseUrl: base, token: token, client: server.client);

    final result = await api.analyze(audio: audio, durationSeconds: 10);

    expect(result.chiefComplaint, isNotEmpty);
    expect(server.calls.where((c) => c.method == 'PUT'), hasLength(2));
    expect(server.calls.last.url.path, '/api/analyze');
  });

  test('PUT 실패 — 재시도도 실패하면 업로드 실패 문구, 분석은 부르지 않는다', () async {
    final server = fakeServer(putStatuses: [503, 503]);
    final api = AnalysisApi(baseUrl: base, token: token, client: server.client);

    final message = await failureMessage(
      api.analyze(audio: audio, durationSeconds: 10),
    );

    expect(message, contains('파일 업로드에 실패'));
    expect(server.calls.where((c) => c.method == 'PUT'), hasLength(2));
    expect(server.calls.any((c) => c.url.path == '/api/analyze'), isFalse);
  });

  test('PUT 403(서명 불일치)은 다시 보내도 같으므로 재시도하지 않는다', () async {
    final server = fakeServer(putStatuses: [403]);
    final api = AnalysisApi(baseUrl: base, token: token, client: server.client);

    final message = await failureMessage(
      api.analyze(audio: audio, durationSeconds: 10),
    );

    expect(message, contains('파일 업로드에 실패'));
    expect(server.calls.where((c) => c.method == 'PUT'), hasLength(1));
  });

  test('2초 미만 녹음 — 서버를 전혀 부르지 않고 빈 결과', () async {
    final server = fakeServer();
    final api = AnalysisApi(baseUrl: base, token: token, client: server.client);

    final result = await api.analyze(audio: audio, durationSeconds: 1);

    expect(result.chiefComplaint, isEmpty);
    expect(result.reasons, isEmpty);
    expect(server.calls, isEmpty);
  });

  test('분석 오류 코드별 대원용 문구', () async {
    Future<String> messageFor(int status, String detail) {
      final server = fakeServer(
        analyzeStatus: status,
        analyzeError: {'detail': detail},
      );
      final api = AnalysisApi(baseUrl: base, token: token, client: server.client);
      return failureMessage(api.analyze(audio: audio, durationSeconds: 10));
    }

    expect(await messageFor(400, '업로드된 오디오를 찾을 수 없음'),
        contains('분석 요청이 올바르지 않습니다'));
    expect(await messageFor(502, 'Vertex AI 오류(500)'),
        contains('AI 분석에 일시적인 문제'));
    expect(await messageFor(504, 'Vertex AI 응답 시간 초과'),
        contains('분석 시간이 초과'));
    expect(await messageFor(500, '분석 중 서버 오류'), contains('(500)'));
  });
}
