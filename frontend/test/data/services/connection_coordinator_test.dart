import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/models/connection_profile.dart';
import 'package:pointy_frontend/src/data/services/backend_discovery_service.dart';
import 'package:pointy_frontend/src/data/services/connection_coordinator.dart';
import 'package:pointy_frontend/src/data/services/connection_profile_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';

void main() {
  test(
    'bootstrap discovers LAN backend and authenticated pairing saves relay fallback',
    () async {
      final storage = MemoryConnectionProfileStorage(deviceId: 'device-1');
      final client = MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.toString() ==
                'http://lan.test/api/discovery/service/') {
          return _jsonResponse({
            'service': 'pointy-backend',
            'version': 1,
            'backend_url': 'http://lan.test',
            'api_base_url': 'http://lan.test/api',
            'shop_name': 'متجر آمن',
            'installation_id': 'installation-1',
            'remote_access_supported': true,
            'relay_public_api_url': 'https://relay.test',
          });
        }
        if (request.method == 'POST' &&
            request.url.toString() == 'http://lan.test/api/relay/pairing/') {
          expect(jsonDecode(request.body), {'device_id': 'device-1'});
          return _jsonResponse({
            'remote_access_supported': true,
            'installation_id': 'installation-1',
            'shop_name': 'متجر آمن',
            'relay_public_api_url': 'https://relay.test',
            'relay_token': 'ptt1.installation-1.ticket',
            'expires_at': '2026-06-02T12:15:00Z',
            'reason': '',
          });
        }
        return http.Response('', 404);
      });
      final service = PosApiService(
        client: client,
        baseUrl: 'http://lan.test/api',
      );
      final coordinator = ConnectionCoordinator(
        service: service,
        discovery: BackendDiscoveryService(
          client: client,
          defaultApiBaseUrl: 'http://lan.test/api',
        ),
        storage: storage,
      );

      await coordinator.bootstrap();
      await coordinator.pairAuthenticatedDevice();

      final profile = await storage.loadProfile();
      expect(service.baseUrl, 'http://lan.test/api');
      expect(service.usesRelay, isFalse);
      expect(profile?.localApiBaseUrl, 'http://lan.test/api');
      expect(profile?.relayApiBaseUrl, 'https://relay.test/api');
      expect(profile?.relayToken, 'ptt1.installation-1.ticket');
      expect(profile?.installationId, 'installation-1');
    },
  );

  test('bootstrap uses stored relay target when LAN discovery fails', () async {
    final storage = MemoryConnectionProfileStorage(
      profile: const ConnectionProfile(
        localApiBaseUrl: 'http://lan.test/api',
        relayApiBaseUrl: 'https://relay.test/api',
        relayToken: 'ptt1.installation-1.ticket',
        installationId: 'installation-1',
        shopName: 'متجر آمن',
      ),
    );
    final client = MockClient((request) async => http.Response('', 404));
    final service = PosApiService(
      client: client,
      baseUrl: 'http://lan.test/api',
    );
    final coordinator = ConnectionCoordinator(
      service: service,
      discovery: BackendDiscoveryService(
        client: client,
        defaultApiBaseUrl: 'http://lan.test/api',
      ),
      storage: storage,
    );

    await coordinator.bootstrap();

    expect(service.baseUrl, 'https://relay.test/api');
    expect(service.usesRelay, isTrue);
  });
}

http.Response _jsonResponse(Map<String, Object?> body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
}
