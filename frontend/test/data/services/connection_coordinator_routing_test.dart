// Where a till's requests go — the shop's LAN or the relay — across the
// situations a shop actually produces: a slow server, the server machine's own
// till, a phone carried home, a relay refresh racing the way back to the LAN.
//
// The world below is one shop: a server on the LAN that can be up, slow,
// wedged, switched off or out of reach, a relay that always answers, and the
// device's own network addresses. Timings are milliseconds here; production
// runs seconds to minutes on the same logic.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/models/connection_profile.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/services/backend_discovery_service.dart';
import 'package:pointy_frontend/src/data/services/connection_coordinator.dart';
import 'package:pointy_frontend/src/data/services/connection_profile_storage.dart';
import 'package:pointy_frontend/src/data/services/connection_status_controller.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/relay_ticket_refresh_client.dart';

const _lanIp = '192.168.1.10';
const _lanApi = 'http://192.168.1.10:8000/api';
const _relayApi = 'https://relay.test/api';

const _brisk = Duration(milliseconds: 40);
const _patient = Duration(milliseconds: 500);
const _udp = Duration(milliseconds: 60);
const _awayUdp = Duration(milliseconds: 10);

const _oldTicket = 'ptt1.installation-1.old';
const _oldRefresh = 'ptrf1.installation-1.old-refresh';
const _newTicket = 'ptt1.installation-1.new';
const _newRefresh = 'ptrf1.installation-1.new-refresh';

/// The shop's server, as the network shows it to the till.
enum _Server {
  /// Answers, after [_World.answerDelay].
  up,

  /// Accepts connections and never answers: a wedged backend.
  wedged,

  /// Refuses connections: the server is off, or restarting.
  off,

  /// Nothing comes back at all: the till is on another network.
  unreachable,
}

class _World {
  _Server server = _Server.up;
  String serverAddress = _lanIp;
  Duration answerDelay = Duration.zero;
  String installationId = 'installation-1';

  /// Whether the server also answers on this machine's loopback: the till
  /// running on the server PC itself.
  bool serverIsThisMachine = false;

  /// Whether the server answers UDP broadcast.
  bool broadcastAnswered = true;

  /// LAN API requests to fail with a dropped connection before answering.
  int connectionDropsAhead = 0;

  /// While set, ticket exchanges at the relay wait for it.
  Completer<void>? exchangeGate;

  /// API requests the relay refuses for carrying this ticket.
  String? refusedTicket;

  List<String> ownAddresses = ['192.168.1.50'];

  int discoveryProbes = 0;
  int sweeps = 0;
  int exchanges = 0;
  int lanApiRequests = 0;
  int relayApiRequests = 0;
  final List<String?> relayTicketsSeen = [];
  Duration? lastBroadcastListen;

  bool _isServerHost(String host) =>
      host == serverAddress ||
      (serverIsThisMachine && (host == '127.0.0.1' || host == 'localhost'));

  late final MockClient client = MockClient((request) async {
    final url = request.url;
    if (url.host == 'relay.test') {
      return _relay(request);
    }
    if (!_isServerHost(url.host)) {
      throw http.ClientException('Connection refused', url);
    }
    final isDiscovery = url.path == '/api/discovery/service/';
    if (isDiscovery) {
      discoveryProbes++;
    }
    switch (server) {
      case _Server.unreachable:
      case _Server.wedged:
        return Completer<http.Response>().future;
      case _Server.off:
        throw http.ClientException('Connection refused', url);
      case _Server.up:
        break;
    }
    if (!isDiscovery && connectionDropsAhead > 0) {
      connectionDropsAhead--;
      throw http.ClientException(
        'Connection closed before full header was received',
        url,
      );
    }
    if (answerDelay > Duration.zero) {
      await Future<void>.delayed(answerDelay);
    }
    if (isDiscovery) {
      return _json({
        'service': 'pointy-backend',
        'api_base_url': 'http://${url.host}:8000/api',
        'installation_id': installationId,
        'shop_name': 'متجر آمن',
      });
    }
    lanApiRequests++;
    return _json(_emptyPage);
  });

  Future<http.Response> _relay(http.Request request) async {
    if (request.url.path == '/v1/relay-ticket-refresh') {
      exchanges++;
      await exchangeGate?.future;
      final now = DateTime.now().toUtc();
      return _json({
        'installation_id': 'installation-1',
        'token': _newTicket,
        'issued_at': now.toIso8601String(),
        'expires_at': now.add(const Duration(minutes: 15)).toIso8601String(),
        'refresh_token': _newRefresh,
        'refresh_expires_at': now
            .add(const Duration(days: 7))
            .toIso8601String(),
      }, statusCode: 201);
    }
    final ticket = request.headers['X-Pointy-Relay-Token'];
    relayTicketsSeen.add(ticket);
    if (ticket != null && ticket == refusedTicket) {
      return http.Response(
        jsonEncode({'error': 'relay token rejected'}),
        401,
        headers: {'content-type': 'application/json'},
      );
    }
    relayApiRequests++;
    return _json(_emptyPage);
  }

  Future<List<Uri>> broadcast({Duration timeout = _udp}) async {
    lastBroadcastListen = timeout;
    if (server == _Server.up && broadcastAnswered) {
      return [Uri.parse('http://$serverAddress:8000/api')];
    }
    await Future<void>.delayed(timeout);
    return const [];
  }

  Future<List<String>> sweep({String? expectedInstallationId}) async {
    sweeps++;
    return server == _Server.up ? ['http://$serverAddress:8000/api'] : [];
  }

  Future<bool> accepts(Uri url, {Duration timeout = _brisk}) async =>
      _isServerHost(url.host) &&
      (server == _Server.up || server == _Server.wedged);
}

/// One till: its stored profile, its API session, and the coordinator, with
/// every phase it passes through.
class _Till {
  _Till(
    this.world, {
    ConnectionProfile? profile,
    List<Duration> startupLooks = const [
      Duration.zero,
      Duration(milliseconds: 10),
    ],
    List<Duration> returnLooks = const [Duration(milliseconds: 20)],
    Duration resumeCheckAfter = const Duration(milliseconds: 30),
  }) : storage = MemoryConnectionProfileStorage(
         deviceId: 'device-1',
         profile: profile,
       ) {
    service = PosApiService(client: world.client, baseUrl: _lanApi);
    coordinator = ConnectionCoordinator(
      service: service,
      discovery: BackendDiscoveryService(
        client: world.client,
        defaultApiBaseUrl: 'http://127.0.0.1:8000/api',
        probeTimeout: _brisk,
        patientProbeTimeout: _patient,
        udpTimeout: _udp,
        awayUdpTimeout: _awayUdp,
        udpDiscovery: world.broadcast,
        subnetSweep: world.sweep,
        serverPresence: world.accepts,
        readAddresses: () async => [
          for (final address in world.ownAddresses)
            (interfaceName: 'wlan0', address: address),
        ],
      ),
      storage: storage,
      status: status,
      relayTicketRefreshClient: RelayTicketRefreshClient(client: world.client),
      startupRecoveryBackoffs: startupLooks,
      localReturnBackoffs: returnLooks,
      resumeCheckAfter: resumeCheckAfter,
    );
    service.onLocalTargetUnreachable = coordinator.notifyLocalTargetUnreachable;
    service.onRelayTicketRejected =
        coordinator.refreshRelayTicketAfterRejection;
    status.addListener(() {
      if (phases.isEmpty || phases.last != status.phase) {
        phases.add(status.phase);
      }
    });
  }

  final _World world;
  final MemoryConnectionProfileStorage storage;
  final ConnectionStatusController status = ConnectionStatusController();
  late final PosApiService service;
  late final ConnectionCoordinator coordinator;
  final List<ConnectionPhase> phases = [];

  ConnectionPhase get phase => status.phase;

  Future<ConnectionProfile> get profile async => (await storage.loadProfile())!;

  Future<void> fetch() => service.fetchProducts(query: const ProductQuery());

  void dispose() => coordinator.dispose();
}

ConnectionProfile _relayReady({String localApiBaseUrl = _lanApi}) {
  final now = DateTime.now().toUtc();
  return ConnectionProfile(
    localApiBaseUrl: localApiBaseUrl,
    relayApiBaseUrl: _relayApi,
    relayToken: _oldTicket,
    relayRefreshToken: _oldRefresh,
    installationId: 'installation-1',
    shopName: 'متجر آمن',
    relayTokenExpiresAt: now.add(const Duration(hours: 1)),
    relayRefreshExpiresAt: now.add(const Duration(days: 7)),
  );
}

ConnectionProfile _ticketExpired() {
  final now = DateTime.now().toUtc();
  return _relayReady().copyWith(
    relayTokenExpiresAt: now.subtract(const Duration(minutes: 1)),
  );
}

const _lanOnly = ConnectionProfile(
  localApiBaseUrl: _lanApi,
  relayApiBaseUrl: '',
  relayToken: '',
  installationId: 'installation-1',
  shopName: 'متجر آمن',
);

void main() {
  late _World world;
  late _Till till;

  _Till build({
    ConnectionProfile? profile,
    List<Duration> startupLooks = const [
      Duration.zero,
      Duration(milliseconds: 10),
    ],
    List<Duration> returnLooks = const [Duration(milliseconds: 20)],
  }) {
    return till = _Till(
      world,
      profile: profile ?? _relayReady(),
      startupLooks: startupLooks,
      returnLooks: returnLooks,
    );
  }

  setUp(() => world = _World());
  tearDown(() => till.dispose());

  group('starting up in the shop', () {
    test(
      'a server that answers: the LAN, and nothing sent to the relay',
      () async {
        build();

        await till.coordinator.bootstrap();

        expect(till.phase, ConnectionPhase.connectedLocal);
        expect(till.service.usesRelay, isFalse);
        expect(world.exchanges, 0);
        expect(world.relayApiRequests, 0);
      },
    );

    // The reported bug: a till sitting next to its server came up on the
    // relay, because the server took longer than the race's deadline to
    // answer its first request.
    test('a server slow to answer still keeps the till on the LAN', () async {
      world.answerDelay = const Duration(milliseconds: 200);
      build();

      await till.coordinator.bootstrap();

      expect(till.phase, ConnectionPhase.connectedLocal);
      expect(till.phases, isNot(contains(ConnectionPhase.connectedRelay)));
      expect(till.service.baseUrl, _lanApi);
      expect(world.relayApiRequests, 0);
    });

    test("the server machine's own till, slow behind its port forward, "
        'stays on the LAN', () async {
      world
        ..serverIsThisMachine = true
        ..answerDelay = const Duration(milliseconds: 200)
        ..ownAddresses = [_lanIp];
      build(profile: _relayReady(localApiBaseUrl: 'http://127.0.0.1:8000/api'));

      await till.coordinator.bootstrap();

      expect(till.phase, ConnectionPhase.connectedLocal);
      expect(till.service.usesRelay, isFalse);
      expect(world.relayApiRequests, 0);
    });

    test('a server that accepts but never answers: the relay, once the '
        'patient wait is over', () async {
      world.server = _Server.wedged;
      build();

      final stopwatch = Stopwatch()..start();
      await till.coordinator.bootstrap();

      expect(till.phase, ConnectionPhase.connectedRelay);
      expect(till.service.usesRelay, isTrue);
      expect(stopwatch.elapsed, greaterThanOrEqualTo(_patient));
    });

    test('a server that is off: the relay, without the patient wait', () async {
      world.server = _Server.off;
      build();

      final stopwatch = Stopwatch()..start();
      await till.coordinator.bootstrap();

      expect(till.phase, ConnectionPhase.connectedRelay);
      expect(stopwatch.elapsed, lessThan(_patient));
    });
  });

  group('starting up away from the shop', () {
    test('on another network, the relay comes as quickly as ever', () async {
      world
        ..server = _Server.unreachable
        ..ownAddresses = ['10.20.30.40'];
      build();

      final stopwatch = Stopwatch()..start();
      await till.coordinator.bootstrap();

      expect(till.phase, ConnectionPhase.connectedRelay);
      expect(till.service.baseUrl, _relayApi);
      expect(
        world.lastBroadcastListen,
        _awayUdp,
        reason: 'not the shop network: broadcast listens only briefly',
      );
      expect(stopwatch.elapsed, lessThan(_patient));
    });

    // Home routers hand out the same 192.168.1.x as the shop's. Nothing can
    // tell those apart, so the full broadcast listen runs — but nothing
    // accepts a connection at the shop's address, so nothing waits longer.
    test('at home on the same subnet number, still no patient wait', () async {
      world
        ..server = _Server.unreachable
        ..ownAddresses = ['192.168.1.77'];
      build();

      final stopwatch = Stopwatch()..start();
      await till.coordinator.bootstrap();

      expect(till.phase, ConnectionPhase.connectedRelay);
      expect(world.lastBroadcastListen, _udp);
      expect(stopwatch.elapsed, lessThan(_patient));
    });

    test(
      'an expired ticket is renewed from the refresh token on the way',
      () async {
        world
          ..server = _Server.unreachable
          ..ownAddresses = ['10.20.30.40'];
        build(profile: _ticketExpired());

        await till.coordinator.bootstrap();
        await till.fetch();

        expect(till.phase, ConnectionPhase.connectedRelay);
        expect(world.exchanges, 1);
        expect(world.relayTicketsSeen, [_newTicket]);
      },
    );
  });

  group('a hiccup while working on the LAN', () {
    test('a connection the server had already closed costs one retry, not a '
        'trip to the relay', () async {
      build();
      await till.coordinator.bootstrap();
      world.connectionDropsAhead = 1;

      await till.fetch();

      expect(till.service.usesRelay, isFalse);
      expect(world.relayApiRequests, 0);
      expect(world.lanApiRequests, 1);
      expect(till.phases, [
        ConnectionPhase.connecting,
        ConnectionPhase.connectedLocal,
      ]);
    });

    // A rescue moved the session onto the relay. The way back used to wait
    // for the first return look — or for the debounce, when a recovery had
    // run in the last few seconds — while the till ran over the internet.
    test('a request the relay rescued is back on the LAN at once, however '
        'soon after the last', () async {
      build(returnLooks: const [Duration(seconds: 30)]);
      await till.coordinator.bootstrap();

      for (var hiccup = 0; hiccup < 2; hiccup++) {
        world.connectionDropsAhead = 2;
        await till.fetch();
        expect(world.relayApiRequests, hiccup + 1, reason: 'rescued');

        final back = Stopwatch()..start();
        await _eventually(
          () => till.phase == ConnectionPhase.connectedLocal,
          'back on the LAN after hiccup $hiccup',
        );
        expect(back.elapsed, lessThan(const Duration(seconds: 1)));
        expect(till.service.usesRelay, isFalse);
      }
    });

    test(
      'a LAN that stops answering moves to the relay before any sweep',
      () async {
        build();
        await till.coordinator.bootstrap();
        int? sweepsAtMove;
        till.status.addListener(() {
          if (till.phase == ConnectionPhase.connectedRelay) {
            sweepsAtMove ??= world.sweeps;
          }
        });
        world.server = _Server.off;

        till.coordinator.notifyLocalTargetUnreachable();
        await _eventually(
          () => till.phase == ConnectionPhase.connectedRelay,
          'on the relay',
        );

        expect(sweepsAtMove, 0, reason: 'the quick race decided it');
        await _eventually(() => world.sweeps > 0, 'the hunt sweeps after');
      },
    );

    test('with no relay to fall back on, the sweep finds a server that '
        'moved', () async {
      build(profile: _lanOnly);
      await till.coordinator.bootstrap();
      world
        ..serverAddress = '192.168.1.20'
        ..broadcastAnswered = false;

      till.coordinator.notifyLocalTargetUnreachable();
      await _eventually(
        () => till.service.baseUrl == 'http://192.168.1.20:8000/api',
        'found at its new address',
      );

      expect(till.phase, ConnectionPhase.connectedLocal);
      expect(world.sweeps, greaterThan(0));
    });
  });

  group('a ticket exchange racing the way back to the LAN', () {
    Future<void> startOnRelay() async {
      world.server = _Server.off;
      await till.coordinator.bootstrap();
      expect(till.phase, ConnectionPhase.connectedRelay);
    }

    // The exchange used to install its ticket on the relay whatever had
    // happened meanwhile: the session went back onto the internet path while
    // the phase still said LAN and the hunt had stopped, so nothing brought it
    // back until the app was restarted.
    test('a refresh that lands after the LAN was found leaves the till on '
        'the LAN, with the new ticket as its way out', () async {
      build();
      await startOnRelay();
      world.exchangeGate = Completer<void>();
      final refresh = till.coordinator.refreshRelayTicketIfNeeded(force: true);
      await _eventually(() => world.exchanges == 1, 'the exchange is out');

      world.server = _Server.up;
      await _eventually(
        () => till.phase == ConnectionPhase.connectedLocal,
        'back on the LAN',
      );
      world.exchangeGate!.complete();
      await refresh;

      expect(till.service.usesRelay, isFalse);
      expect(till.service.baseUrl, _lanApi);
      expect(till.phase, ConnectionPhase.connectedLocal);
      expect((await till.profile).relayToken, _newTicket);

      // The fresh ticket is what a rescue now carries.
      world.server = _Server.off;
      await till.fetch();
      expect(world.relayTicketsSeen.last, _newTicket);
    });

    test('a request the relay refused while the LAN came back is answered on '
        'the LAN, not handed back as a sign-out', () async {
      build();
      await startOnRelay();
      world
        ..refusedTicket = _oldTicket
        ..exchangeGate = Completer<void>();
      final request = till.fetch();
      await _eventually(() => world.exchanges == 1, 'the exchange is out');

      world.server = _Server.up;
      await _eventually(
        () => till.phase == ConnectionPhase.connectedLocal,
        'back on the LAN',
      );
      world.exchangeGate!.complete();

      await request;
      expect(world.lanApiRequests, 1);
      expect(till.service.usesRelay, isFalse);
    });

    test('the move to the relay at startup does not undo a LAN found '
        'meanwhile', () async {
      world.server = _Server.off;
      build(profile: _ticketExpired());
      world.exchangeGate = Completer<void>();
      final bootstrap = till.coordinator.bootstrap();
      await _eventually(() => world.exchanges == 1, 'minting a ticket');

      // The app comes to the foreground while the ticket is minted, and the
      // server answers by now.
      world.server = _Server.up;
      await till.coordinator.noteAppResumed();
      expect(till.phase, ConnectionPhase.connectedLocal);
      world.exchangeGate!.complete();
      await bootstrap;

      expect(till.phase, ConnectionPhase.connectedLocal);
      expect(till.service.usesRelay, isFalse);
      expect(till.phases.last, ConnectionPhase.connectedLocal);
      expect(till.phases, isNot(contains(ConnectionPhase.connectedRelay)));
    });
  });

  group('writes to the stored profile that overlap', () {
    // Each writer used to save a copy it had read before going to the
    // network, over whatever the other had saved meanwhile.
    test(
      'a ticket saved while the server moved keeps the new address',
      () async {
        build();
        world.server = _Server.off;
        await till.coordinator.bootstrap();
        world.exchangeGate = Completer<void>();
        final refresh = till.coordinator.refreshRelayTicketIfNeeded(
          force: true,
        );
        await _eventually(() => world.exchanges == 1, 'the exchange is out');

        world
          ..serverAddress = '192.168.1.20'
          ..server = _Server.up;
        await _eventually(
          () => till.phase == ConnectionPhase.connectedLocal,
          'found at its new address',
        );
        world.exchangeGate!.complete();
        await refresh;

        final profile = await till.profile;
        expect(profile.localApiBaseUrl, 'http://192.168.1.20:8000/api');
        expect(profile.relayToken, _newTicket);
        expect(profile.relayRefreshToken, _newRefresh);
      },
    );

    // The refresh token is spent the moment the relay reads it. Writing the
    // old one back left the device with a token the relay would refuse: its
    // way in from outside the shop, gone.
    test(
      'a LAN found while a ticket was saved keeps the new refresh token',
      () async {
        build();
        world.server = _Server.off;
        await till.coordinator.bootstrap();

        world
          ..answerDelay = const Duration(milliseconds: 200)
          ..server = _Server.up;
        final probesBefore = world.discoveryProbes;
        await _eventually(
          () => world.discoveryProbes > probesBefore,
          'a look is under way',
        );
        await till.coordinator.refreshRelayTicketIfNeeded(force: true);
        expect((await till.profile).relayRefreshToken, _newRefresh);

        await _eventually(
          () => till.phase == ConnectionPhase.connectedLocal,
          'the look lands',
        );
        final profile = await till.profile;
        expect(profile.relayRefreshToken, _newRefresh);
        expect(profile.relayToken, _newTicket);
      },
    );
  });

  group('coming back to the app', () {
    test(
      'carried out of the shop: the relay, before the screens ask',
      () async {
        build();
        await till.coordinator.bootstrap();
        till.coordinator.noteAppHidden();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        world
          ..ownAddresses = ['10.20.30.40']
          ..server = _Server.unreachable;

        final stopwatch = Stopwatch()..start();
        await till.coordinator.noteAppResumed();

        expect(till.phase, ConnectionPhase.connectedRelay);
        expect(till.service.baseUrl, _relayApi);
        expect(stopwatch.elapsed, lessThan(_patient));
      },
    );

    test(
      'back in the shop after a while: checked, and still the LAN',
      () async {
        build();
        await till.coordinator.bootstrap();
        till.coordinator.noteAppHidden();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final probesBefore = world.discoveryProbes;

        await till.coordinator.noteAppResumed();

        expect(world.discoveryProbes, greaterThan(probesBefore));
        expect(till.phase, ConnectionPhase.connectedLocal);
        expect(till.service.usesRelay, isFalse);
        expect(world.relayApiRequests, 0);
      },
    );

    test('a glance away does not look at all', () async {
      build();
      await till.coordinator.bootstrap();
      final probesBefore = world.discoveryProbes;

      till.coordinator.noteAppHidden();
      await till.coordinator.noteAppResumed();

      expect(world.discoveryProbes, probesBefore);
    });

    test('on the relay, coming back looks for the LAN', () async {
      build(returnLooks: const [Duration(seconds: 30)]);
      world.server = _Server.off;
      await till.coordinator.bootstrap();
      // Past the quick startup looks; the next one is half a minute away.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _eventually(
        () => !till.status.searchingInBackground,
        'the startup looks are done',
      );
      world.server = _Server.up;

      await till.coordinator.noteAppResumed();

      expect(till.phase, ConnectionPhase.connectedLocal);
    });

    test('an app that chose its own target is left alone', () async {
      build();
      final probesBefore = world.discoveryProbes;

      till.coordinator.noteAppHidden();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await till.coordinator.noteAppResumed();

      expect(world.discoveryProbes, probesBefore);
      expect(till.phase, ConnectionPhase.connecting);
    });
  });

  test(
    "another shop's server: the old shop's relay credentials are dropped",
    () async {
      build();
      await till.coordinator.bootstrap();
      world.installationId = 'installation-2';

      expect(await till.coordinator.connectManually(_lanIp), isTrue);

      final profile = await till.profile;
      expect(profile.installationId, 'installation-2');
      expect(profile.relayToken, isEmpty);
      expect(profile.relayRefreshToken, isEmpty);
      // A LAN failure now has no way out to the other shop's relay.
      world.server = _Server.off;
      await expectLater(till.fetch(), throwsA(isA<Exception>()));
      expect(world.relayTicketsSeen, isEmpty);
    },
  );

  test('off the LAN, the hunt still finds a server slow to answer', () async {
    build();
    world.server = _Server.off;
    await till.coordinator.bootstrap();

    world
      ..answerDelay = const Duration(milliseconds: 200)
      ..server = _Server.up;
    await _eventually(
      () => till.phase == ConnectionPhase.connectedLocal,
      'found by the hunt',
    );
    expect(till.service.usesRelay, isFalse);
  });
}

const _emptyPage = <String, Object?>{
  'count': 0,
  'next': null,
  'previous': null,
  'results': <Object?>[],
};

http.Response _json(Map<String, Object?> body, {int statusCode = 200}) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Future<void> _eventually(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting until $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
