import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/backend_discovery_service.dart';

void main() {
  group('loopback candidates', () {
    test('a native build keeps both loopback spellings', () {
      expect(loopbackApiBaseUrls(isWeb: false, pageHost: 'anything'), [
        'http://127.0.0.1:8000/api',
        'http://localhost:8000/api',
      ]);
    });

    test('a web build follows the page it was served from', () {
      // The bug this pins: a page on 127.0.0.1 that adopted the backend on
      // localhost (or the reverse — it was a race) received a SameSite=Lax
      // session cookie it could never send back, so the login POST returned 200
      // and every request after it returned 401. To a browser these two are the
      // same machine but different SITES.
      expect(loopbackApiBaseUrls(isWeb: true, pageHost: '127.0.0.1'), [
        'http://127.0.0.1:8000/api',
      ]);
      expect(loopbackApiBaseUrls(isWeb: true, pageHost: 'localhost'), [
        'http://localhost:8000/api',
      ]);
    });

    test('a web build never offers the other spelling', () {
      final candidates = loopbackApiBaseUrls(
        isWeb: true,
        pageHost: '127.0.0.1',
      );
      expect(candidates, isNot(contains('http://localhost:8000/api')));
    });

    test('a web build served from a LAN address looks there, not at loopback', () {
      expect(loopbackApiBaseUrls(isWeb: true, pageHost: '192.168.1.5'), [
        'http://192.168.1.5:8000/api',
      ]);
    });

    test('a web build with no resolvable host offers nothing', () {
      // Only the same-origin default remains, which is what the production web
      // build (nginx serving the app and proxying /api) wants anyway.
      expect(loopbackApiBaseUrls(isWeb: true, pageHost: ''), isEmpty);
    });
  });
}
