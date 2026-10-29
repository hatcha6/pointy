import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/models/connection_profile.dart';
import 'package:pointy_frontend/src/data/services/backend_discovery_service.dart';
import 'package:pointy_frontend/src/data/services/connection_coordinator.dart';
import 'package:pointy_frontend/src/data/services/connection_profile_storage.dart';
import 'package:pointy_frontend/src/data/services/connection_status_controller.dart';
import 'package:pointy_frontend/src/data/services/lan_interfaces.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/auth/view_models/login_failure.dart';

const _shop = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d';

/// A relay at relay.test whose sign-in route leads to one shop, [_shop].
class _Relay {
  _Relay({
    this.enabled = true,
    this.loginCode,
    this.pairingTicket = 'ptt1.shop.ticket',
  });

  final bool enabled;

  /// The backend's refusal code for the sign-in, or null to let it through.
  final String? loginCode;
  final String pairingTicket;
  final requests = <http.Request>[];

  late final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    final installation = request.headers['X-Pointy-Relay-Installation'];
    final ticket = request.headers['X-Pointy-Relay-Token'];
    if (ticket == null && installation != _shop) {
      return _json({'error': 'invalid relay token'}, 401);
    }
    if (path == '/api/relay/remote-sign-in/') {
      return _json({
        'enabled': enabled,
        'shop_name': enabled ? 'متجر آمن' : '',
      });
    }
    if (path == '/api/auth/login/') {
      if (loginCode case final code?) {
        return _json({'code': code, 'detail': code}, 403);
      }
      return _json({
        'user': {'id': 1, 'username': 'owner', 'role': 'manager'},
        'csrf_token': 'csrf',
      });
    }
    if (path == '/api/auth/logout/') {
      return http.Response('', 204);
    }
    if (path == '/api/relay/pairing/') {
      return _json({
        'remote_access_supported': pairingTicket.isNotEmpty,
        'installation_id': _shop,
        'shop_name': 'متجر آمن',
        'relay_public_api_url': 'https://relay.test',
        'relay_token': pairingTicket,
        'expires_at': '2099-01-01T00:00:00Z',
        'relay_refresh_token': pairingTicket.isEmpty ? '' : 'ptrf1.refresh',
        'refresh_expires_at': '2099-02-01T00:00:00Z',
        'reason': pairingTicket.isEmpty ? 'relay_not_active' : '',
      });
    }
    return http.Response('', 404);
  });
}

({
  ConnectionCoordinator coordinator,
  PosApiService service,
  MemoryConnectionProfileStorage storage,
  ConnectionStatusController status,
})
_world(_Relay relay, {ConnectionProfile? profile}) {
  final storage = MemoryConnectionProfileStorage(
    deviceId: 'iphone',
    profile:
        profile ??
        const ConnectionProfile(
          localApiBaseUrl: 'http://lan.test/api',
          relayApiBaseUrl: 'https://relay.test/api',
          relayToken: '',
          installationId: '',
          shopName: '',
        ),
  );
  final service = PosApiService(
    client: relay.client,
    baseUrl: 'http://lan.test/api',
  );
  final status = ConnectionStatusController();
  final coordinator = ConnectionCoordinator(
    service: service,
    discovery: BackendDiscoveryService(
      client: relay.client,
      defaultApiBaseUrl: 'http://lan.test/api',
      serverPresence: (url, {timeout = Duration.zero}) async => false,
      readAddresses: () async => const <LanAddressCandidate>[],
      udpDiscovery: ({timeout = Duration.zero}) async => const <Uri>[],
    ),
    storage: storage,
    status: status,
    searchesLan: false,
  );
  service.onSignedInRemotely = coordinator.completeRemoteSignIn;
  addTearDown(coordinator.dispose);
  return (
    coordinator: coordinator,
    service: service,
    storage: storage,
    status: status,
  );
}

void main() {
  test(
    'a manager signs in through the relay and comes out with a ticket',
    () async {
      final relay = _Relay();
      final world = _world(relay);

      final outcome = await world.coordinator.connectThroughRelay(
        ' ${_shop.toUpperCase()} ',
      );

      expect(outcome, RemoteConnectOutcome.signInRequired);
      expect(world.status.phase, ConnectionPhase.connectedRelay);
      expect(world.status.shopName, 'متجر آمن');
      expect(world.service.signsInRemotely, isTrue);
      expect(relay.requests.last.headers['X-Pointy-Relay-Installation'], _shop);

      await world.service.login(username: 'owner', password: 'pass');

      expect(world.service.signsInRemotely, isFalse);
      expect(world.service.usesRelay, isTrue);
      expect(world.service.baseUrl, 'https://relay.test/api');
      final profile = await world.storage.loadProfile();
      expect(profile?.installationId, _shop);
      expect(profile?.relayToken, 'ptt1.shop.ticket');
      expect(profile?.relayRefreshToken, 'ptrf1.refresh');
      // Another shop's LAN address is no address for this one.
      expect(profile?.localApiBaseUrl, '');
    },
  );

  test('an unknown or unpaid installation is not found', () async {
    final world = _world(_Relay());
    final outcome = await world.coordinator.connectThroughRelay(
      'ffffffff-ffff-4fff-8fff-ffffffffffff',
    );
    expect(outcome, RemoteConnectOutcome.notFound);
    expect(world.status.phase, isNot(ConnectionPhase.connectedRelay));
  });

  test('a malformed ID never leaves the device', () async {
    final relay = _Relay();
    final world = _world(relay);
    expect(
      await world.coordinator.connectThroughRelay('192.168.1.10'),
      RemoteConnectOutcome.notFound,
    );
    expect(relay.requests, isEmpty);
  });

  test('a shop with remote sign-in off says so before any password', () async {
    final world = _world(_Relay(enabled: false));
    expect(
      await world.coordinator.connectThroughRelay(_shop),
      RemoteConnectOutcome.disabled,
    );
  });

  test('a cashier is refused with its own reason', () async {
    final world = _world(_Relay(loginCode: 'remote_sign_in_not_allowed'));
    await world.coordinator.connectThroughRelay(_shop);
    Object? error;
    try {
      await world.service.login(username: 'till', password: 'pass');
    } on Object catch (caught) {
      error = caught;
    }
    expect(
      classifyLoginFailure(error!, viaRelay: false),
      LoginFailure.remoteSignInNotAllowed,
    );
  });

  test('a sign-in the shop gives no ticket for fails and signs out', () async {
    final relay = _Relay(pairingTicket: '');
    final world = _world(relay);
    await world.coordinator.connectThroughRelay(_shop);
    Object? error;
    try {
      await world.service.login(username: 'owner', password: 'pass');
    } on Object catch (caught) {
      error = caught;
    }
    expect(error, isA<RemoteSignInPairingException>());
    expect(
      classifyLoginFailure(error!, viaRelay: true),
      LoginFailure.relaySubscriptionInactive,
    );
    expect(relay.requests.last.url.path, '/api/auth/logout/');
  });

  test(
    'a device that already has a ticket for the shop just uses it',
    () async {
      final relay = _Relay();
      final world = _world(
        relay,
        profile: const ConnectionProfile(
          localApiBaseUrl: '',
          relayApiBaseUrl: 'https://relay.test/api',
          relayToken: 'ptt1.shop.kept',
          installationId: _shop,
          shopName: 'متجر آمن',
        ),
      );
      expect(
        await world.coordinator.connectThroughRelay(_shop),
        RemoteConnectOutcome.connected,
      );
      expect(world.service.usesRelay, isTrue);
      expect(relay.requests, isEmpty);
    },
  );

  test('without a shop network the app starts on the relay form', () async {
    final relay = _Relay();
    final world = _world(relay);
    await world.coordinator.bootstrap();
    expect(world.status.phase, ConnectionPhase.needsManual);
    expect(relay.requests, isEmpty, reason: 'no LAN probe from the web app');
  });
}

/// A JSON answer; the relay's own refusals carry an `error` key, which is
/// how the app tells them from the backend's.
http.Response _json(Map<String, Object?> body, [int status = 200]) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}
