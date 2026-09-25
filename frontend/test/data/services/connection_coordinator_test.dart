import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/models/connection_profile.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/backend_discovery_service.dart';
import 'package:pointy_frontend/src/data/services/connection_coordinator.dart';
import 'package:pointy_frontend/src/data/services/connection_status_controller.dart';
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
          udpDiscovery: _noUdp,
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
        udpDiscovery: _noUdp,
      ),
      storage: storage,
    );

    await coordinator.bootstrap();

    expect(service.baseUrl, 'https://relay.test/api');
    expect(service.usesRelay, isTrue);
    coordinator.dispose();
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
        udpDiscovery: _noUdp,
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
        udpDiscovery: _noUdp,
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
          udpDiscovery: _noUdp,
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
          udpDiscovery: _noUdp,
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
        udpDiscovery: _noUdp,
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

  test(
    'stale stored IP is ignored; UDP result for the right shop wins',
    () async {
      // The server moved from old.lan to new.lan. old.lan now answers as a
      // *different* shop (installation-other) — a classic DHCP reassignment.
      final storage = MemoryConnectionProfileStorage(
        profile: const ConnectionProfile(
          localApiBaseUrl: 'http://old.lan/api',
          relayApiBaseUrl: '',
          relayToken: '',
          installationId: 'installation-1',
          shopName: 'متجر آمن',
        ),
      );
      final client = MockClient((request) async {
        final url = request.url.toString();
        if (url == 'http://old.lan/api/discovery/service/') {
          return _jsonResponse(
            _backendPayload(
              installationId: 'installation-other',
              apiBaseUrl: 'http://old.lan/api',
            ),
          );
        }
        if (url == 'http://new.lan/api/discovery/service/') {
          return _jsonResponse(
            _backendPayload(
              installationId: 'installation-1',
              apiBaseUrl: 'http://new.lan/api',
            ),
          );
        }
        return http.Response('', 404);
      });
      final service = PosApiService(
        client: client,
        baseUrl: 'http://old.lan/api',
      );
      final coordinator = ConnectionCoordinator(
        service: service,
        discovery: BackendDiscoveryService(
          client: client,
          defaultApiBaseUrl: 'http://old.lan/api',
          udpDiscovery:
              ({Duration timeout = const Duration(seconds: 2)}) async => [
                Uri.parse('http://new.lan/api'),
              ],
        ),
        storage: storage,
      );

      await coordinator.bootstrap();

      // The stale IP (wrong shop) is rejected; the moved server wins.
      expect(service.baseUrl, 'http://new.lan/api');
      final profile = await storage.loadProfile();
      expect(profile?.localApiBaseUrl, 'http://new.lan/api');
      expect(profile?.installationId, 'installation-1');
      coordinator.dispose();
    },
  );

  test(
    'subnet sweep recovers the backend when broadcast finds nothing',
    () async {
      final storage = MemoryConnectionProfileStorage(
        profile: const ConnectionProfile(
          localApiBaseUrl: 'http://old.lan/api',
          relayApiBaseUrl: '',
          relayToken: '',
          installationId: 'installation-1',
          shopName: 'متجر آمن',
        ),
      );
      final client = MockClient((request) async {
        if (request.url.toString() ==
            'http://swept.lan/api/discovery/service/') {
          return _jsonResponse(
            _backendPayload(
              installationId: 'installation-1',
              apiBaseUrl: 'http://swept.lan/api',
            ),
          );
        }
        return http.Response('', 404);
      });
      final service = PosApiService(
        client: client,
        baseUrl: 'http://old.lan/api',
      );
      final coordinator = ConnectionCoordinator(
        service: service,
        discovery: BackendDiscoveryService(
          client: client,
          defaultApiBaseUrl: 'http://old.lan/api',
          udpDiscovery: _noUdp,
          subnetSweep: ({String? expectedInstallationId}) async => [
            'http://swept.lan/api',
          ],
        ),
        storage: storage,
      );

      final found = await coordinator.rediscover(includeSweep: true);

      expect(found, isTrue);
      expect(service.baseUrl, 'http://swept.lan/api');
      coordinator.dispose();
    },
  );

  test('connectManually connects to a typed address and saves it', () async {
    final storage = MemoryConnectionProfileStorage();
    final client = MockClient((request) async {
      if (request.url.toString() ==
          'http://192.168.1.50:8000/api/discovery/service/') {
        return _jsonResponse(
          _backendPayload(
            installationId: 'installation-9',
            apiBaseUrl: 'http://192.168.1.50:8000/api',
          ),
        );
      }
      return http.Response('', 404);
    });
    final service = PosApiService(
      client: client,
      baseUrl: 'http://127.0.0.1:8000/api',
    );
    final coordinator = ConnectionCoordinator(
      service: service,
      discovery: BackendDiscoveryService(
        client: client,
        defaultApiBaseUrl: 'http://127.0.0.1:8000/api',
        udpDiscovery: _noUdp,
      ),
      storage: storage,
    );

    // Bare IP with no scheme/port/path — normalization fills in the rest.
    final connected = await coordinator.connectManually('192.168.1.50');

    expect(connected, isTrue);
    expect(service.baseUrl, 'http://192.168.1.50:8000/api');
    final profile = await storage.loadProfile();
    expect(profile?.localApiBaseUrl, 'http://192.168.1.50:8000/api');
    coordinator.dispose();
  });

  test(
    'connectManually returns false when the address does not answer',
    () async {
      final storage = MemoryConnectionProfileStorage();
      final client = MockClient((request) async => http.Response('', 404));
      final service = PosApiService(
        client: client,
        baseUrl: 'http://127.0.0.1:8000/api',
      );
      final coordinator = ConnectionCoordinator(
        service: service,
        discovery: BackendDiscoveryService(
          client: client,
          defaultApiBaseUrl: 'http://127.0.0.1:8000/api',
          udpDiscovery: _noUdp,
        ),
        storage: storage,
      );

      final connected = await coordinator.connectManually(
        'http://nope.lan/api',
      );

      expect(connected, isFalse);
      expect(service.baseUrl, 'http://127.0.0.1:8000/api');
      coordinator.dispose();
    },
  );

  test(
    'connectManually waits for a server the discovery race would give up on',
    () async {
      // A typed address races nothing: the operator is waiting on this one
      // answer. On Windows the server answers from behind a port forward and a
      // VM, and a slow first answer used to read as "no server here".
      final storage = MemoryConnectionProfileStorage();
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (request.url.toString() ==
            'http://192.168.1.50:8000/api/discovery/service/') {
          return _jsonResponse(
            _backendPayload(
              installationId: 'installation-9',
              apiBaseUrl: 'http://192.168.1.50:8000/api',
            ),
          );
        }
        return http.Response('', 404);
      });
      final service = PosApiService(
        client: client,
        baseUrl: 'http://127.0.0.1:8000/api',
      );
      final coordinator = ConnectionCoordinator(
        service: service,
        discovery: BackendDiscoveryService(
          client: client,
          defaultApiBaseUrl: 'http://127.0.0.1:8000/api',
          udpDiscovery: _noUdp,
          probeTimeout: const Duration(milliseconds: 50),
        ),
        storage: storage,
      );

      expect(await coordinator.connectManually('192.168.1.50'), isTrue);
      expect(service.baseUrl, 'http://192.168.1.50:8000/api');
      coordinator.dispose();
    },
  );

  test('rediscover is single-flight', () async {
    final storage = MemoryConnectionProfileStorage();
    final client = MockClient((request) async {
      if (request.url.toString() == 'http://lan.test/api/discovery/service/') {
        return _jsonResponse(
          _backendPayload(
            installationId: 'installation-1',
            apiBaseUrl: 'http://lan.test/api',
          ),
        );
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
        udpDiscovery: _noUdp,
      ),
      storage: storage,
    );

    final first = coordinator.rediscover(includeSweep: false);
    // Second call while the first is still in flight coalesces to a no-op.
    final second = coordinator.rediscover(includeSweep: false);

    expect(await second, isFalse);
    expect(await first, isTrue);
    coordinator.dispose();
  });

  test('status controller reflects a successful LAN connection', () async {
    final storage = MemoryConnectionProfileStorage();
    final status = ConnectionStatusController();
    final client = MockClient((request) async {
      if (request.url.toString() == 'http://lan.test/api/discovery/service/') {
        return _jsonResponse(
          _backendPayload(
            installationId: 'installation-1',
            apiBaseUrl: 'http://lan.test/api',
          ),
        );
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
        udpDiscovery: _noUdp,
      ),
      storage: storage,
      status: status,
    );

    await coordinator.bootstrap();

    expect(status.phase, ConnectionPhase.connectedLocal);
    expect(status.isReady, isTrue);
    coordinator.dispose();
  });

  group('coming back from the relay', () {
    // Milliseconds here; the real schedule runs seconds to minutes.
    const startupLooks = [Duration.zero, Duration(milliseconds: 10)];
    const returnLooks = [Duration(milliseconds: 20)];

    late _ShopNetwork shop;
    late ConnectionStatusController status;
    late PosApiService service;
    late ConnectionCoordinator coordinator;

    void build(ConnectionProfile profile) {
      final storage = MemoryConnectionProfileStorage(
        deviceId: 'device-1',
        profile: profile,
      );
      status = ConnectionStatusController();
      service = PosApiService(client: shop.client, baseUrl: _lanApi);
      coordinator = ConnectionCoordinator(
        service: service,
        discovery: BackendDiscoveryService(
          client: shop.client,
          defaultApiBaseUrl: _lanApi,
          udpDiscovery: _noUdp,
          subnetSweep: _noSweep,
        ),
        storage: storage,
        status: status,
        startupRecoveryBackoffs: startupLooks,
        localReturnBackoffs: returnLooks,
      );
      service.onLocalTargetUnreachable =
          coordinator.notifyLocalTargetUnreachable;
    }

    setUp(() => shop = _ShopNetwork());
    tearDown(() => coordinator.dispose());

    test('a request the relay rescued shows the relay at once, and the till '
        'returns to the LAN when it answers again', () async {
      build(_relayCapableProfile());
      await coordinator.bootstrap();
      expect(status.phase, ConnectionPhase.connectedLocal);

      shop.lanUp = false;
      await service.fetchProducts(query: const ProductQuery());

      expect(service.usesRelay, isTrue, reason: 'the relay answered it');
      expect(
        status.phase,
        ConnectionPhase.connectedRelay,
        reason: 'and the phase says so, instead of still claiming the LAN',
      );

      shop.lanUp = true;
      await _eventually(
        () => status.phase == ConnectionPhase.connectedLocal,
        'the till returns to the LAN',
      );
      expect(service.usesRelay, isFalse);
      expect(service.baseUrl, _lanApi);
    });

    // A phone that walked out of the shop's Wi-Fi: its LAN requests time out,
    // which never moves the session by itself. The coordinator moves it once
    // the LAN has failed discovery as well.
    test(
      'a LAN that stops answering discovery moves the session to the relay',
      () async {
        build(_relayCapableProfile());
        await coordinator.bootstrap();
        shop.lanUp = false;

        coordinator.notifyLocalTargetUnreachable();

        await _eventually(
          () => status.phase == ConnectionPhase.connectedRelay,
          'moved to the relay',
        );
        expect(service.baseUrl, _relayApi);

        shop.lanUp = true;
        await _eventually(
          () => status.phase == ConnectionPhase.connectedLocal,
          'and back once the LAN answers',
        );
        expect(service.usesRelay, isFalse);
      },
    );

    // A slow backend: one request timed out, but the server still answers
    // discovery. Nothing moves — and re-finding the same server must not throw
    // away the cache every screen revalidates against.
    test('a LAN that still answers keeps the session and its cache', () async {
      build(_relayCapableProfile());
      await coordinator.bootstrap();
      await service.fetchProducts(query: const ProductQuery());
      final lookedBefore = shop.discoveries;

      coordinator.notifyLocalTargetUnreachable();
      await _eventually(
        () => shop.discoveries > lookedBefore && !status.searchingInBackground,
        'the rediscovery finishes',
      );
      await service.fetchProducts(query: const ProductQuery());

      expect(service.usesRelay, isFalse);
      expect(status.phase, ConnectionPhase.connectedLocal);
      expect(
        shop.lanIfNoneMatch.last,
        'W/"catalog-v1"',
        reason: 'the ETag cache survived re-finding the same server',
      );
    });

    test('a till that boots before its server keeps looking past the startup '
        'looks', () async {
      shop.lanUp = false;
      build(_relayCapableProfile());
      await coordinator.bootstrap();
      expect(status.phase, ConnectionPhase.connectedRelay);

      // The bootstrap look, both startup looks, and two more: the old
      // recovery gave up for good after the startup looks.
      await _eventually(() => shop.discoveries >= 5, 'still looking');
      expect(status.phase, ConnectionPhase.connectedRelay);

      shop.lanUp = true;
      await _eventually(
        () => status.phase == ConnectionPhase.connectedLocal,
        'found the server once it came up',
      );
      expect(service.usesRelay, isFalse);
    });

    test('with no way onto the relay, the manual-address screen still '
        'connects once the server answers', () async {
      shop.lanUp = false;
      build(
        const ConnectionProfile(
          localApiBaseUrl: _lanApi,
          relayApiBaseUrl: '',
          relayToken: '',
          installationId: 'installation-1',
          shopName: 'متجر آمن',
        ),
      );
      await coordinator.bootstrap();
      expect(status.phase, ConnectionPhase.needsManual);

      shop.lanUp = true;
      await _eventually(
        () => status.phase == ConnectionPhase.connectedLocal,
        'connected without anyone typing an address',
      );
    });

    test('the hunt stops once the till is back on the LAN', () async {
      shop.lanUp = false;
      build(_relayCapableProfile());
      await coordinator.bootstrap();
      shop.lanUp = true;
      await _eventually(
        () => status.phase == ConnectionPhase.connectedLocal,
        'back on the LAN',
      );

      final settled = shop.discoveries;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(shop.discoveries, settled);
    });

    test('dispose stops the hunt', () async {
      shop.lanUp = false;
      build(_relayCapableProfile());
      await coordinator.bootstrap();

      coordinator.dispose();
      // Let a look already in flight finish before counting.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final settled = shop.discoveries;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(shop.discoveries, settled);
    });

    // A server rebuilt on the same IP is a different installation; its answers
    // must not be matched against the old one's cached bodies and counters.
    test(
      'a different installation at the same address starts from nothing',
      () async {
        build(_relayCapableProfile());
        await coordinator.bootstrap();
        await service.fetchProducts(query: const ProductQuery());

        shop.installationId = 'installation-rebuilt';
        expect(await coordinator.connectManually(_lanApi), isTrue);
        await service.fetchProducts(query: const ProductQuery());

        expect(shop.lanIfNoneMatch.last, isNull);
      },
    );
  });
  group('a ticket the relay refuses', () {
    late MemoryConnectionProfileStorage storage;

    ConnectionProfile relayPairedProfile({
      Duration ticketFor = const Duration(hours: 1),
    }) {
      return ConnectionProfile(
        localApiBaseUrl: _lanApi,
        relayApiBaseUrl: _relayApi,
        relayToken: 'ptt1.installation-1.old',
        relayRefreshToken: 'ptrf1.installation-1.refresh',
        installationId: 'installation-1',
        shopName: 'متجر آمن',
        relayTokenExpiresAt: DateTime.now().toUtc().add(ticketFor),
        relayRefreshExpiresAt: DateTime.now().toUtc().add(
          const Duration(days: 1),
        ),
      );
    }

    http.Response mintedTicket() => _jsonResponse({
      'installation_id': 'installation-1',
      'device_id': 'device-1',
      'token': 'ptt1.installation-1.new',
      'expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 15))
          .toIso8601String(),
      'refresh_token': 'ptrf1.installation-1.new-refresh',
      'refresh_expires_at': '2026-06-09T12:00:00Z',
    }, statusCode: 201);

    http.Response relayRefusal() => http.Response(
      jsonEncode({'error': 'relay token rejected'}),
      401,
      headers: {'content-type': 'application/json'},
    );

    ConnectionCoordinator buildOnRelay(
      MockClient client, {
      required PosApiService service,
    }) {
      service.configureConnectionTarget(
        baseUrl: _relayApi,
        relayToken: 'ptt1.installation-1.old',
      );
      return ConnectionCoordinator(
        service: service,
        discovery: BackendDiscoveryService(
          client: client,
          defaultApiBaseUrl: _lanApi,
          udpDiscovery: _noUdp,
          subnetSweep: _noSweep,
        ),
        storage: storage,
        relayTicketRefreshClient: RelayTicketRefreshClient(client: client),
      );
    }

    setUp(() {
      storage = MemoryConnectionProfileStorage(
        deviceId: 'device-1',
        profile: relayPairedProfile(),
      );
    });

    // Every request in flight meets the same 401 at once; the refresh token
    // is consumed the moment the relay reads it, so only one exchange may
    // happen and the rest must wait for it.
    test(
      'concurrent rejections share one exchange of the refresh token',
      () async {
        var refreshRequests = 0;
        final client = MockClient((request) async {
          if (request.url.path == '/v1/relay-ticket-refresh') {
            refreshRequests++;
            expect(
              request.headers['X-Pointy-Relay-Refresh-Token'],
              'ptrf1.installation-1.refresh',
            );
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return mintedTicket();
          }
          return http.Response('', 404);
        });
        final service = PosApiService(client: client, baseUrl: _relayApi);
        final coordinator = buildOnRelay(client, service: service);
        addTearDown(coordinator.dispose);

        final answers = await Future.wait([
          coordinator.refreshRelayTicketAfterRejection(),
          coordinator.refreshRelayTicketAfterRejection(),
          coordinator.refreshRelayTicketAfterRejection(),
        ]);

        expect(answers, [
          RelayTicketRecovery.refreshed,
          RelayTicketRecovery.refreshed,
          RelayTicketRecovery.refreshed,
        ]);
        expect(refreshRequests, 1);
        final profile = await storage.loadProfile();
        expect(profile?.relayToken, 'ptt1.installation-1.new');
        expect(profile?.relayRefreshToken, 'ptrf1.installation-1.new-refresh');
        expect(service.usesRelay, isTrue);
      },
    );

    test('a request the relay refused goes through on the ticket minted from '
        'the refresh token', () async {
      final ticketsSeen = <String?>[];
      var refreshRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/v1/relay-ticket-refresh') {
          refreshRequests++;
          return mintedTicket();
        }
        final ticket = request.headers['X-Pointy-Relay-Token'];
        ticketsSeen.add(ticket);
        if (ticket == 'ptt1.installation-1.old') {
          return relayRefusal();
        }
        return _jsonResponse(_emptyProductPage);
      });
      final service = PosApiService(client: client, baseUrl: _relayApi);
      final coordinator = buildOnRelay(client, service: service);
      addTearDown(coordinator.dispose);
      service.onRelayTicketRejected =
          coordinator.refreshRelayTicketAfterRejection;

      await service.fetchProducts(query: const ProductQuery());

      expect(ticketsSeen, [
        'ptt1.installation-1.old',
        'ptt1.installation-1.new',
      ]);
      expect(refreshRequests, 1);
    });

    test(
      'a refresh the relay refuses drops the credentials and answers no',
      () async {
        final client = MockClient((request) async {
          if (request.url.path == '/v1/relay-ticket-refresh') {
            return relayRefusal();
          }
          return http.Response('', 404);
        });
        final service = PosApiService(client: client, baseUrl: _relayApi);
        final coordinator = buildOnRelay(client, service: service);
        addTearDown(coordinator.dispose);

        expect(
          await coordinator.refreshRelayTicketAfterRejection(),
          RelayTicketRecovery.failed,
        );

        final profile = await storage.loadProfile();
        expect(profile?.relayToken, isEmpty);
        expect(profile?.relayRefreshToken, isEmpty);
      },
    );

    // A LAN pairing saved a fresh pair while this exchange was on the wire.
    // The refusal is about the old token and says nothing about the new one.
    test(
      "a refused exchange leaves credentials saved meanwhile alone",
      () async {
        final client = MockClient((request) async {
          if (request.url.path == '/v1/relay-ticket-refresh') {
            await storage.saveProfile(
              relayPairedProfile().copyWith(
                relayToken: 'ptt1.installation-1.paired',
                relayRefreshToken: 'ptrf1.installation-1.paired-refresh',
              ),
            );
            return relayRefusal();
          }
          return http.Response('', 404);
        });
        final service = PosApiService(client: client, baseUrl: _relayApi);
        final coordinator = buildOnRelay(client, service: service);
        addTearDown(coordinator.dispose);

        expect(
          await coordinator.refreshRelayTicketAfterRejection(),
          RelayTicketRecovery.failed,
        );

        final profile = await storage.loadProfile();
        expect(
          profile?.relayRefreshToken,
          'ptrf1.installation-1.paired-refresh',
        );
        expect(profile?.relayToken, 'ptt1.installation-1.paired');
      },
    );

    // The relay answers a lapsed subscription before spending the token, so
    // the device keeps its way back in for when the subscription returns —
    // and the answer is remembered, so the burst of refused requests that
    // follows is not a burst of exchanges.
    test('a subscription the relay says is off keeps the credentials and is '
        'remembered', () async {
      var refreshRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/v1/relay-ticket-refresh') {
          refreshRequests++;
          return http.Response(
            jsonEncode({'error': 'relay subscription inactive'}),
            402,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      });
      final service = PosApiService(client: client, baseUrl: _relayApi);
      final coordinator = buildOnRelay(client, service: service);
      addTearDown(coordinator.dispose);

      expect(
        await coordinator.refreshRelayTicketAfterRejection(),
        RelayTicketRecovery.subscriptionInactive,
      );
      expect(
        await coordinator.refreshRelayTicketAfterRejection(),
        RelayTicketRecovery.subscriptionInactive,
      );

      expect(refreshRequests, 1, reason: 'the second answer came from memory');
      final profile = await storage.loadProfile();
      expect(profile?.relayRefreshToken, 'ptrf1.installation-1.refresh');
      expect(profile?.relayToken, 'ptt1.installation-1.old');
    });

    test(
      'a relay that cannot be reached keeps the credentials for next time',
      () async {
        final client = MockClient((request) async {
          throw http.ClientException('Network is unreachable', request.url);
        });
        final service = PosApiService(client: client, baseUrl: _relayApi);
        final coordinator = buildOnRelay(client, service: service);
        addTearDown(coordinator.dispose);

        expect(
          await coordinator.refreshRelayTicketAfterRejection(),
          RelayTicketRecovery.failed,
        );

        final profile = await storage.loadProfile();
        expect(profile?.relayRefreshToken, 'ptrf1.installation-1.refresh');
      },
    );
  });

  group('a pairing answer without a ticket', () {
    Map<String, Object?> noTicket(String reason) => {
      'remote_access_supported': false,
      'installation_id': 'installation-1',
      'shop_name': 'متجر آمن',
      'relay_public_api_url': 'https://relay.test',
      'relay_token': '',
      'expires_at': null,
      'relay_refresh_token': '',
      'refresh_expires_at': null,
      'reason': reason,
    };

    ConnectionProfile lanPairedProfile({required Duration ticketFor}) {
      return ConnectionProfile(
        localApiBaseUrl: _lanApi,
        relayApiBaseUrl: _relayApi,
        relayToken: 'ptt1.installation-1.old',
        relayRefreshToken: 'ptrf1.installation-1.refresh',
        installationId: 'installation-1',
        shopName: 'متجر آمن',
        relayTokenExpiresAt: DateTime.now().toUtc().add(ticketFor),
        relayRefreshExpiresAt: DateTime.now().toUtc().add(
          const Duration(days: 1),
        ),
      );
    }

    // The backend's link to the relay was down at sign-in. That used to
    // throw away the refresh token — the device's only way in from outside
    // the shop — for a hiccup on the shop's side.
    test('keeps the credentials the device already holds', () async {
      final storage = MemoryConnectionProfileStorage(
        deviceId: 'device-1',
        profile: lanPairedProfile(ticketFor: const Duration(hours: 1)),
      );
      final client = MockClient((request) async {
        if (request.url.path == '/api/relay/pairing/') {
          return _jsonResponse(noTicket('relay_unavailable'));
        }
        fail('only pairing was expected, not ${request.url}');
      });
      final service = PosApiService(client: client, baseUrl: _lanApi);
      final coordinator = ConnectionCoordinator(
        service: service,
        discovery: BackendDiscoveryService(
          client: client,
          defaultApiBaseUrl: _lanApi,
          udpDiscovery: _noUdp,
          subnetSweep: _noSweep,
        ),
        storage: storage,
        relayTicketRefreshClient: RelayTicketRefreshClient(client: client),
      );
      addTearDown(coordinator.dispose);

      await coordinator.pairAuthenticatedDevice();

      final profile = await storage.loadProfile();
      expect(profile?.relayToken, 'ptt1.installation-1.old');
      expect(profile?.relayRefreshToken, 'ptrf1.installation-1.refresh');
      expect(profile?.hasUsableRelayTarget, isTrue);
      expect(service.usesRelay, isFalse);
    });

    test('asks the relay directly when the ticket is due', () async {
      final storage = MemoryConnectionProfileStorage(
        deviceId: 'device-1',
        profile: lanPairedProfile(ticketFor: const Duration(minutes: 2)),
      );
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path == '/api/relay/pairing/') {
          return _jsonResponse(noTicket('relay_unavailable'));
        }
        if (request.url.path == '/v1/relay-ticket-refresh') {
          expect(
            request.headers['X-Pointy-Relay-Refresh-Token'],
            'ptrf1.installation-1.refresh',
          );
          return _jsonResponse({
            'installation_id': 'installation-1',
            'device_id': 'device-1',
            'token': 'ptt1.installation-1.new',
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 15))
                .toIso8601String(),
            'refresh_token': 'ptrf1.installation-1.new-refresh',
            'refresh_expires_at': '2026-06-09T12:00:00Z',
          }, statusCode: 201);
        }
        return http.Response('', 404);
      });
      final service = PosApiService(client: client, baseUrl: _lanApi);
      final coordinator = ConnectionCoordinator(
        service: service,
        discovery: BackendDiscoveryService(
          client: client,
          defaultApiBaseUrl: _lanApi,
          udpDiscovery: _noUdp,
          subnetSweep: _noSweep,
        ),
        storage: storage,
        relayTicketRefreshClient: RelayTicketRefreshClient(client: client),
      );
      addTearDown(coordinator.dispose);

      await coordinator.pairAuthenticatedDevice();

      expect(requests, ['/api/relay/pairing/', '/v1/relay-ticket-refresh']);
      final profile = await storage.loadProfile();
      expect(profile?.relayToken, 'ptt1.installation-1.new');
      expect(profile?.relayRefreshToken, 'ptrf1.installation-1.new-refresh');
      expect(service.usesRelay, isFalse, reason: 'still on the LAN');
    });

    test(
      'keeps asking while the backend says the relay is only unavailable',
      () async {
        final storage = MemoryConnectionProfileStorage(
          deviceId: 'device-1',
          profile: lanPairedProfile(ticketFor: const Duration(minutes: -1)),
        );
        var pairings = 0;
        final client = MockClient((request) async {
          if (request.url.path == '/api/relay/pairing/') {
            pairings++;
            return _jsonResponse(noTicket('relay_unavailable'));
          }
          throw http.ClientException('Network is unreachable', request.url);
        });
        final service = PosApiService(client: client, baseUrl: _lanApi);
        final coordinator = ConnectionCoordinator(
          service: service,
          discovery: BackendDiscoveryService(
            client: client,
            defaultApiBaseUrl: _lanApi,
            udpDiscovery: _noUdp,
            subnetSweep: _noSweep,
          ),
          storage: storage,
          relayTicketRefreshClient: RelayTicketRefreshClient(client: client),
          pairingRetryDelay: const Duration(milliseconds: 30),
        );
        addTearDown(coordinator.dispose);

        await coordinator.pairAuthenticatedDevice();
        expect(pairings, 1);
        expect(
          (await storage.loadProfile())?.relayRefreshToken,
          'ptrf1.installation-1.refresh',
          reason: 'the refresh token survives the failed attempt',
        );

        await _eventually(() => pairings >= 2, 'the next attempt');
      },
    );

    // The phone's clock runs twelve minutes ahead of the relay's. Read as
    // absolute timestamps the fresh 15-minute ticket has three minutes left
    // and is due at once; read against the relay's own issue time it has
    // its full fifteen.
    test("reads the expiry in the device's own clock", () async {
      final storage = MemoryConnectionProfileStorage(
        deviceId: 'device-1',
        profile: const ConnectionProfile(
          localApiBaseUrl: _lanApi,
          relayApiBaseUrl: _relayApi,
          relayToken: '',
          installationId: 'installation-1',
          shopName: 'متجر آمن',
        ),
      );
      final relayNow = DateTime.now().toUtc().subtract(
        const Duration(minutes: 12),
      );
      final client = MockClient((request) async {
        if (request.url.path == '/api/relay/pairing/') {
          return _jsonResponse({
            'remote_access_supported': true,
            'installation_id': 'installation-1',
            'shop_name': 'متجر آمن',
            'relay_public_api_url': 'https://relay.test',
            'relay_token': 'ptt1.installation-1.new',
            'issued_at': relayNow.toIso8601String(),
            'expires_at': relayNow
                .add(const Duration(minutes: 15))
                .toIso8601String(),
            'relay_refresh_token': 'ptrf1.installation-1.refresh',
            'refresh_expires_at': relayNow
                .add(const Duration(days: 7))
                .toIso8601String(),
            'reason': '',
          });
        }
        fail('only pairing was expected, not ${request.url}');
      });
      final service = PosApiService(client: client, baseUrl: _lanApi);
      final coordinator = ConnectionCoordinator(
        service: service,
        discovery: BackendDiscoveryService(
          client: client,
          defaultApiBaseUrl: _lanApi,
          udpDiscovery: _noUdp,
          subnetSweep: _noSweep,
        ),
        storage: storage,
        relayTicketRefreshClient: RelayTicketRefreshClient(client: client),
      );
      addTearDown(coordinator.dispose);

      await coordinator.pairAuthenticatedDevice();

      final profile = await storage.loadProfile();
      final now = DateTime.now().toUtc();
      final expiresIn = profile!.relayTokenExpiresAt!.difference(now);
      expect(expiresIn.inSeconds, closeTo(15 * 60, 10));
      expect(
        profile.shouldRefreshRelayTicketAt(now, const Duration(minutes: 5)),
        isFalse,
      );
      final refreshExpiresIn = profile.relayRefreshExpiresAt!.difference(now);
      expect(refreshExpiresIn.inMinutes, closeTo(7 * 24 * 60, 1));
    });

    test('does not keep asking a shop that has no remote access', () async {
      final storage = MemoryConnectionProfileStorage(
        deviceId: 'device-1',
        profile: const ConnectionProfile(
          localApiBaseUrl: _lanApi,
          relayApiBaseUrl: _relayApi,
          relayToken: '',
          installationId: 'installation-1',
          shopName: 'متجر آمن',
        ),
      );
      var pairings = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/api/relay/pairing/') {
          pairings++;
          return _jsonResponse(noTicket('relay_not_active'));
        }
        fail('nothing but pairing was expected, not ${request.url}');
      });
      final service = PosApiService(client: client, baseUrl: _lanApi);
      final coordinator = ConnectionCoordinator(
        service: service,
        discovery: BackendDiscoveryService(
          client: client,
          defaultApiBaseUrl: _lanApi,
          udpDiscovery: _noUdp,
          subnetSweep: _noSweep,
        ),
        storage: storage,
        relayTicketRefreshClient: RelayTicketRefreshClient(client: client),
        pairingRetryDelay: const Duration(milliseconds: 20),
      );
      addTearDown(coordinator.dispose);

      await coordinator.pairAuthenticatedDevice();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(pairings, 1);
      expect((await storage.loadProfile())?.relayToken, isEmpty);
    });
  });
}

const _lanApi = 'http://lan.test/api';
const _relayApi = 'https://relay.test/api';

/// A subnet sweep that finds nothing, so a hunt never touches the real LAN.
Future<List<String>> _noSweep({String? expectedInstallationId}) async {
  return const [];
}

ConnectionProfile _relayCapableProfile() {
  return ConnectionProfile(
    localApiBaseUrl: _lanApi,
    relayApiBaseUrl: _relayApi,
    relayToken: 'ptt1.installation-1.ticket',
    installationId: 'installation-1',
    shopName: 'متجر آمن',
    relayTokenExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  );
}

/// The shop's server on the LAN, which can be switched off and on, and the
/// relay, which always answers.
class _ShopNetwork {
  bool lanUp = true;
  String installationId = 'installation-1';

  /// Discovery probes that reached the LAN address, up or not.
  int discoveries = 0;

  /// The If-None-Match of each catalog request that reached the LAN server.
  final List<String?> lanIfNoneMatch = [];

  late final MockClient client = MockClient((request) async {
    final url = request.url;
    if (url.host == 'lan.test') {
      final isDiscovery = url.path == '/api/discovery/service/';
      if (isDiscovery) {
        discoveries++;
      }
      if (!lanUp) {
        throw http.ClientException('Connection refused', url);
      }
      if (isDiscovery) {
        return _jsonResponse(
          _backendPayload(installationId: installationId, apiBaseUrl: _lanApi),
        );
      }
      const etag = 'W/"catalog-v1"';
      lanIfNoneMatch.add(request.headers['If-None-Match']);
      if (request.headers['If-None-Match'] == etag) {
        return http.Response('', 304, headers: {'etag': etag});
      }
      return http.Response(
        jsonEncode(_emptyProductPage),
        200,
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'etag': etag,
        },
      );
    }
    if (url.host == 'relay.test') {
      return _jsonResponse(_emptyProductPage);
    }
    return http.Response('', 404);
  });
}

const _emptyProductPage = <String, Object?>{
  'count': 0,
  'next': null,
  'previous': null,
  'results': <Object?>[],
};

Future<void> _eventually(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting until $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// No-op UDP discovery so tests never open real sockets.
Future<List<Uri>> _noUdp({
  Duration timeout = const Duration(seconds: 2),
}) async {
  return const [];
}

Map<String, Object?> _backendPayload({
  required String installationId,
  required String apiBaseUrl,
}) {
  return {
    'service': 'pointy-backend',
    'version': 1,
    'backend_url': apiBaseUrl.replaceFirst('/api', ''),
    'api_base_url': apiBaseUrl,
    'shop_name': 'متجر آمن',
    'installation_id': installationId,
    'remote_access_supported': false,
    'relay_public_api_url': '',
  };
}

http.Response _jsonResponse(Map<String, Object?> body, {int statusCode = 200}) {
  // Declare charset so http encodes the (Arabic) body as UTF-8. Without it the
  // http package defaults to latin1, which throws on non-latin1 shop names
  // under older http (compat/win8 pins http 1.2.2).
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}
