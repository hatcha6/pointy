import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/models/connection_profile.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/services/backend_discovery_service.dart';
import 'package:pointy_frontend/src/data/services/connection_coordinator.dart';
import 'package:pointy_frontend/src/data/services/connection_profile_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/relay_ticket_refresh_client.dart';

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
            'relay_refresh_token': 'ptrf1.installation-1.refresh',
            'refresh_expires_at': '2026-06-09T12:00:00Z',
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
      expect(profile?.relayRefreshToken, 'ptrf1.installation-1.refresh');
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

  test('refreshes near-expiry relay ticket over LAN', () async {
    final storage = MemoryConnectionProfileStorage(
      deviceId: 'device-1',
      profile: ConnectionProfile(
        localApiBaseUrl: 'http://lan.test/api',
        relayApiBaseUrl: 'https://relay.test/api',
        relayToken: 'ptt1.installation-1.old',
        installationId: 'installation-1',
        shopName: 'متجر آمن',
        relayTokenExpiresAt: DateTime.now().toUtc().add(
          const Duration(minutes: 1),
        ),
      ),
    );
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.toString(), 'http://lan.test/api/relay/pairing/');
      return _jsonResponse({
        'remote_access_supported': true,
        'installation_id': 'installation-1',
        'shop_name': 'متجر آمن',
        'relay_public_api_url': 'https://relay.test',
        'relay_token': 'ptt1.installation-1.new',
        'expires_at': '2026-06-02T12:30:00Z',
        'relay_refresh_token': 'ptrf1.installation-1.new-refresh',
        'refresh_expires_at': '2026-06-09T12:00:00Z',
        'reason': '',
      });
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

    await coordinator.refreshRelayTicketIfNeeded();

    final profile = await storage.loadProfile();
    expect(profile?.relayToken, 'ptt1.installation-1.new');
    expect(profile?.relayRefreshToken, 'ptrf1.installation-1.new-refresh');
    expect(service.baseUrl, 'http://lan.test/api');
    expect(service.usesRelay, isFalse);
    coordinator.dispose();
  });

  test('refreshes remotely while relay is the active primary target', () async {
    final storage = MemoryConnectionProfileStorage(
      deviceId: 'device-1',
      profile: const ConnectionProfile(
        localApiBaseUrl: 'http://lan.test/api',
        relayApiBaseUrl: 'https://relay.test/api',
        relayToken: 'ptt1.installation-1.ticket',
        relayRefreshToken: 'ptrf1.installation-1.refresh',
        installationId: 'installation-1',
        shopName: 'متجر آمن',
      ),
    );
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://relay.test/v1/relay-ticket-refresh',
      );
      expect(
        request.headers['X-Pointy-Relay-Refresh-Token'],
        'ptrf1.installation-1.refresh',
      );
      expect(jsonDecode(request.body), {'device_id': 'device-1'});
      return _jsonResponse({
        'installation_id': 'installation-1',
        'device_id': 'device-1',
        'token': 'ptt1.installation-1.new',
        'expires_at': '2026-06-02T12:30:00Z',
        'refresh_token': 'ptrf1.installation-1.new-refresh',
        'refresh_expires_at': '2026-06-09T12:00:00Z',
      }, statusCode: 201);
    });
    final service = PosApiService(
      client: client,
      baseUrl: 'https://relay.test/api',
    );
    service.configureConnectionTarget(
      baseUrl: 'https://relay.test/api',
      relayToken: 'ptt1.installation-1.ticket',
    );
    final coordinator = ConnectionCoordinator(
      service: service,
      discovery: BackendDiscoveryService(
        client: client,
        defaultApiBaseUrl: 'http://lan.test/api',
      ),
      storage: storage,
      relayTicketRefreshClient: RelayTicketRefreshClient(client: client),
    );

    await coordinator.refreshRelayTicketIfNeeded(force: true);

    final profile = await storage.loadProfile();
    expect(profile?.relayToken, 'ptt1.installation-1.new');
    expect(profile?.relayRefreshToken, 'ptrf1.installation-1.new-refresh');
    expect(service.baseUrl, 'https://relay.test/api');
    expect(service.usesRelay, isTrue);
    coordinator.dispose();
  });

  test(
    'bootstrap refreshes expired relay ticket remotely when LAN is unavailable',
    () async {
      final storage = MemoryConnectionProfileStorage(
        deviceId: 'device-1',
        profile: ConnectionProfile(
          localApiBaseUrl: 'http://lan.test/api',
          relayApiBaseUrl: 'https://relay.test/api',
          relayToken: 'ptt1.installation-1.expired',
          relayRefreshToken: 'ptrf1.installation-1.refresh',
          installationId: 'installation-1',
          shopName: 'متجر آمن',
          relayTokenExpiresAt: DateTime.now().toUtc().subtract(
            const Duration(minutes: 1),
          ),
          relayRefreshExpiresAt: DateTime.now().toUtc().add(
            const Duration(days: 1),
          ),
        ),
      );
      final client = MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.toString() ==
                'http://lan.test/api/discovery/service/') {
          return http.Response('', 404);
        }
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://relay.test/v1/relay-ticket-refresh',
        );
        expect(
          request.headers['X-Pointy-Relay-Refresh-Token'],
          'ptrf1.installation-1.refresh',
        );
        expect(jsonDecode(request.body), {'device_id': 'device-1'});
        return _jsonResponse({
          'installation_id': 'installation-1',
          'device_id': 'device-1',
          'token': 'ptt1.installation-1.new',
          'expires_at': '2026-06-02T12:30:00Z',
          'refresh_token': 'ptrf1.installation-1.new-refresh',
          'refresh_expires_at': '2026-06-09T12:00:00Z',
        }, statusCode: 201);
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
        relayTicketRefreshClient: RelayTicketRefreshClient(client: client),
      );

      await coordinator.bootstrap();

      final profile = await storage.loadProfile();
      expect(service.baseUrl, 'https://relay.test/api');
      expect(service.usesRelay, isTrue);
      expect(profile?.relayToken, 'ptt1.installation-1.new');
      expect(profile?.relayRefreshToken, 'ptrf1.installation-1.new-refresh');
      coordinator.dispose();
    },
  );

  test(
    'bootstrap clears expired relay refresh when LAN is unavailable',
    () async {
      final storage = MemoryConnectionProfileStorage(
        profile: ConnectionProfile(
          localApiBaseUrl: 'http://lan.test/api',
          relayApiBaseUrl: 'https://relay.test/api',
          relayToken: 'ptt1.installation-1.expired',
          relayRefreshToken: 'ptrf1.installation-1.expired-refresh',
          installationId: 'installation-1',
          shopName: 'متجر آمن',
          relayTokenExpiresAt: DateTime.now().toUtc().subtract(
            const Duration(minutes: 1),
          ),
          relayRefreshExpiresAt: DateTime.now().toUtc().subtract(
            const Duration(minutes: 1),
          ),
        ),
      );
      final client = MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.toString() ==
                'http://lan.test/api/discovery/service/') {
          return http.Response('', 404);
        }
        fail('expired refresh token must not be used for remote setup');
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
        relayTicketRefreshClient: RelayTicketRefreshClient(client: client),
      );

      await coordinator.bootstrap();

      final profile = await storage.loadProfile();
      expect(service.usesRelay, isFalse);
      expect(profile?.relayToken, isEmpty);
      expect(profile?.relayRefreshToken, isEmpty);
      coordinator.dispose();
    },
  );

  test('expired stored relay ticket is cleared after LAN discovery', () async {
    final storage = MemoryConnectionProfileStorage(
      profile: ConnectionProfile(
        localApiBaseUrl: 'http://lan.test/api',
        relayApiBaseUrl: 'https://relay.test/api',
        relayToken: 'ptt1.installation-1.expired',
        installationId: 'installation-1',
        shopName: 'متجر آمن',
        relayTokenExpiresAt: DateTime.now().toUtc().subtract(
          const Duration(minutes: 1),
        ),
      ),
    );
    var productRequests = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET' &&
          request.url.toString() == 'http://lan.test/api/discovery/service/') {
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
      if (request.url.path.endsWith('/products/')) {
        productRequests += 1;
        expect(request.url.host, 'lan.test');
        throw Exception('lan offline');
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
    await expectLater(
      service.fetchProducts(query: const ProductQuery()),
      throwsException,
    );

    final profile = await storage.loadProfile();
    expect(profile?.relayToken, isEmpty);
    expect(productRequests, 1);
    coordinator.dispose();
  });
}

http.Response _jsonResponse(Map<String, Object?> body, {int statusCode = 200}) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: {'content-type': 'application/json'},
  );
}
