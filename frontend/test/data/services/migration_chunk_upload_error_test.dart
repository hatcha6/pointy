import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/migration_api_client.dart';

/// Django's own last-resort 500 page, byte for byte. It opens with a newline,
/// which is why decoding it as JSON fails at line 2, column 1 — the message a
/// shop reported while its server was saying something else entirely.
const _djangoHtml500 =
    '\n<!doctype html>\n<html lang="en">\n<head>\n  <title>Server Error (500)'
    '</title>\n</head>\n<body>\n  <h1>Server Error (500)</h1><p></p>\n</body>'
    '\n</html>\n';

/// What nginx answers when a body is over `client_max_body_size`.
const _nginxHtml413 =
    '<html>\r\n<head><title>413 Request Entity Too Large</title></head>\r\n'
    '<body>\r\n<center><h1>413 Request Entity Too Large</h1></center>\r\n'
    '</body>\r\n</html>\r\n';

MigrationApiClient _clientAnswering(http.Response response) {
  return MigrationApiClient(
    PosApiSession(
      client: MockClient((_) async => response),
      baseUrl: 'http://pointy.test/api',
    ),
  );
}

Future<Object?> _upload(MigrationApiClient client) async {
  try {
    await client.uploadChunk(
      sourceId: 30,
      offset: 0,
      bytes: Uint8List.fromList(const [1, 2, 3]),
    );
  } catch (error) {
    return error;
  }
  return null;
}

void main() {
  group('uploadChunk with a body that is not JSON', () {
    test('a 500 HTML page does not surface as a parse error', () async {
      final error = await _upload(
        _clientAnswering(http.Response(_djangoHtml500, 500)),
      );

      // The old failure: jsonDecode threw before the status code was read, so
      // "Unexpected character (at line 2, character 1)" was the whole report.
      expect(error, isNot(isA<FormatException>()));
      expect(error, isNotNull);
      expect(error.toString(), contains('500'));
    });

    test('a proxy 413 still reports the size refusal', () async {
      final error = await _upload(
        _clientAnswering(http.Response(_nginxHtml413, 413)),
      );

      expect(error, isA<MigrationChunkRejected>());
      expect((error! as MigrationChunkRejected).statusCode, 413);
    });

    test('an empty body is tolerated', () async {
      final error = await _upload(_clientAnswering(http.Response('', 502)));
      expect(error, isNot(isA<FormatException>()));
      expect(error.toString(), contains('502'));
    });
  });

  group('uploadChunk with the JSON the backend now sends', () {
    test('a storage refusal reaches the screen in the server words', () async {
      final error = await _upload(
        _clientAnswering(
          // Bytes, not a string: http.Response encodes a string as latin1,
          // while the session decodes the body as UTF-8 — which is what an
          // Arabic detail actually arrives as.
          http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'detail': 'لا توجد مساحة كافية على الخادم لحفظ الملف.',
              }),
            ),
            400,
          ),
        ),
      );

      expect(error, isA<MigrationChunkRejected>());
      expect(error.toString(), contains('لا توجد مساحة كافية'));
    });

    test('a 409 still re-syncs the caller to the real offset', () async {
      final client = _clientAnswering(
        http.Response(jsonEncode({'received_bytes': 4096}), 409),
      );
      final result = await client.uploadChunk(
        sourceId: 30,
        offset: 0,
        bytes: Uint8List.fromList(const [1, 2, 3]),
      );

      expect(result.conflicted, isTrue);
      expect(result.receivedBytes, 4096);
    });

    test('a success reports the new offset', () async {
      final client = _clientAnswering(
        http.Response(
          jsonEncode({
            'received_bytes': 3,
            'upload_state': 'uploading',
            'upload_percent': 1,
          }),
          200,
        ),
      );
      final result = await client.uploadChunk(
        sourceId: 30,
        offset: 0,
        bytes: Uint8List.fromList(const [1, 2, 3]),
      );

      expect(result.conflicted, isFalse);
      expect(result.receivedBytes, 3);
    });
  });
}
