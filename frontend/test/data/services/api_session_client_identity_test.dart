import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/core/app_version.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';

/// Every request names the install that sent it.
///
/// The backend used to read device and session off the *authenticated* request,
/// so a rejected one recorded nothing identifying at all — which is why 5.1M
/// unauthenticated ingest calls in the field could be counted exactly and still
/// not traced to a machine. These headers are what the backend now records, so
/// they have to be on the wire whether or not the request is going to succeed.
void main() {
  Future<Map<String, String>> capturedHeaders({
    required void Function(PosApiSession session) describe,
  }) async {
    late Map<String, String> headers;
    final session = PosApiSession(
      client: MockClient((request) async {
        headers = request.headers;
        return http.Response('{"ok":true}', 200);
      }),
      baseUrl: 'http://pointy.test/api',
    );
    describe(session);
    await session.get('shop-settings/');
    return headers;
  }

  test('a described client stamps its identity on every request', () async {
    final headers = await capturedHeaders(
      describe: (session) => session.describeClient(
        deviceId: 'kiosk-7',
        platform: 'flutter-windows',
        appVersion: '0.4.3',
      ),
    );

    expect(headers['X-Pointy-Device-Id'], 'kiosk-7');
    expect(headers['X-Pointy-Platform'], 'flutter-windows');
    expect(headers['X-Pointy-App-Version'], '0.4.3');
  });

  test(
    'an undescribed client sends no identity rather than a wrong one',
    () async {
      final headers = await capturedHeaders(describe: (_) {});

      expect(headers.containsKey('X-Pointy-Device-Id'), isFalse);
      expect(headers.containsKey('X-Pointy-App-Version'), isFalse);
    },
  );

  test('a dev build claims no version', () async {
    // kAppVersion comes from --dart-define=POINTY_VERSION, which only release
    // builds set (see .github/workflows/release.yml). An unbuilt run must omit
    // the header, not report something misleading like "1.0.0" from pubspec.
    final headers = await capturedHeaders(
      describe: (session) => session.describeClient(
        deviceId: 'dev-box',
        platform: 'flutter-linux',
      ),
    );

    expect(
      headers['X-Pointy-App-Version'],
      kAppVersion.isEmpty ? isNull : kAppVersion,
    );
  });
}
