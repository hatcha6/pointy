import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/client_update_service.dart';

void main() {
  group('isNewerVersion', () {
    test('compares dotted numeric versions', () {
      expect(isNewerVersion('1.4.0', '1.3.9'), isTrue);
      expect(isNewerVersion('2.0.0', '1.9.9'), isTrue);
      expect(isNewerVersion('1.3.0', '1.3.0'), isFalse);
      expect(isNewerVersion('1.2.0', '1.10.0'), isFalse);
    });

    test('ignores build suffixes', () {
      expect(isNewerVersion('1.4.0+12', '1.4.0+5'), isFalse);
      expect(isNewerVersion('1.4.1+1', '1.4.0+99'), isTrue);
    });
  });

  ClientUpdateService service(
    MockClient client, {
    String running = '1.3.0',
    ClientPlatform platform = ClientPlatform.android,
  }) {
    return ClientUpdateService(
      apiBaseUrl: () => 'http://10.0.0.5:8000/api',
      client: client,
      readRunningVersion: () async => running,
      platform: () => platform,
    );
  }

  test('check() offers an update when the manifest is newer', () async {
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'http://10.0.0.5:8000/clients/manifest.json',
      );
      return http.Response(
        jsonEncode({
          'version': '1.4.0',
          'clients': {
            'android': {
              'version': '1.4.0',
              'file': 'pointy-1.4.0-android-universal.apk',
              'sha256': 'abc',
              'size': 10,
              'url': '/clients/files/pointy-1.4.0-android-universal.apk',
            },
          },
        }),
        200,
      );
    });
    final status = await service(client).check();
    expect(status.hasUpdate, isTrue);
    expect(status.available!.version, '1.4.0');
    expect(
      status.available!.url,
      '/clients/files/pointy-1.4.0-android-universal.apk',
    );
  });

  test('check() reports no update when versions match', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'version': '1.3.0',
          'clients': {
            'android': {
              'version': '1.3.0',
              'file': 'a.apk',
              'sha256': '',
              'size': 1,
              'url': '/clients/files/a.apk',
            },
          },
        }),
        200,
      );
    });
    final status = await service(client).check();
    expect(status.hasUpdate, isFalse);
    expect(status.unsupported, isFalse);
  });

  test('check() offers the linux tarball to linux clients', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'version': '1.4.0',
          'clients': {
            'linux': {
              'version': '1.4.0',
              'file': 'pointy-1.4.0-linux-x64.tar.gz',
              'sha256': 'abc',
              'size': 10,
              'url': '/clients/files/pointy-1.4.0-linux-x64.tar.gz',
            },
          },
        }),
        200,
      );
    });
    final status = await service(
      client,
      platform: ClientPlatform.linux,
    ).check();
    expect(status.hasUpdate, isTrue);
    expect(status.available!.file, 'pointy-1.4.0-linux-x64.tar.gz');
  });

  test('check() is unsupported on web/other platforms', () async {
    final client = MockClient((request) async => http.Response('{}', 200));
    final status = await service(
      client,
      platform: ClientPlatform.unsupported,
    ).check();
    expect(status.unsupported, isTrue);
    expect(status.hasUpdate, isFalse);
  });

  test('check() surfaces an error when the backend is unreachable', () async {
    final client = MockClient((request) async => http.Response('nope', 404));
    final status = await service(client).check();
    expect(status.hasUpdate, isFalse);
    expect(status.error, isNull); // 404 = no manifest, not an error
  });

  group('lanDownloadUrl', () {
    ClientUpdateService urlService(
      String apiBaseUrl, {
      List<String> localAddresses = const [],
    }) {
      return ClientUpdateService(
        apiBaseUrl: () => apiBaseUrl,
        client: MockClient((request) async => http.Response('{}', 200)),
        readRunningVersion: () async => '1.0.0',
        platform: () => ClientPlatform.android,
        localAddresses: () async => [
          for (final address in localAddresses)
            (interfaceName: 'Ethernet', address: address),
        ],
      );
    }

    test('uses the API host when it is already a LAN IP', () async {
      final service = urlService('http://10.0.0.5:8000/api');
      expect(await service.lanDownloadUrl(), 'http://10.0.0.5/clients/');
    });

    test('swaps loopback for the machine LAN address', () async {
      final service = urlService(
        'http://127.0.0.1:8000/api',
        localAddresses: ['192.168.1.20'],
      );
      expect(await service.lanDownloadUrl(), 'http://192.168.1.20/clients/');
    });

    test('resolves a localhost hostname too', () async {
      final service = urlService(
        'http://localhost:8000/api',
        localAddresses: ['192.168.1.20'],
      );
      expect(await service.lanDownloadUrl(), 'http://192.168.1.20/clients/');
    });

    test('prefers the shop-LAN range over VPN-style ranges', () async {
      final service = urlService(
        'http://127.0.0.1:8000/api',
        localAddresses: ['10.8.0.2', '192.168.1.20', '172.20.0.3'],
      );
      expect(await service.lanDownloadUrl(), 'http://192.168.1.20/clients/');
    });

    test('ignores link-local and public addresses', () async {
      final service = urlService(
        'http://127.0.0.1:8000/api',
        localAddresses: ['169.254.12.7', '203.0.113.9', '10.1.2.3'],
      );
      expect(await service.lanDownloadUrl(), 'http://10.1.2.3/clients/');
    });

    test('keeps loopback when no LAN address is found', () async {
      final service = urlService('http://127.0.0.1:8000/api');
      expect(await service.lanDownloadUrl(), 'http://127.0.0.1/clients/');
    });
  });
}
