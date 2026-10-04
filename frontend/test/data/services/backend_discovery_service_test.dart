import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/backend_discovery_service.dart';
import 'package:pointy_frontend/src/data/services/lan_interfaces.dart';

// Milliseconds here; production runs 900 ms / 6 s / 2 s / 800 ms.
const _brisk = Duration(milliseconds: 60);
const _patient = Duration(milliseconds: 600);
const _udp = Duration(milliseconds: 150);
const _awayUdp = Duration(milliseconds: 15);

const _server = 'http://192.168.1.10:8000/api';

/// A LAN with one server at 192.168.1.10 that can be slow, silent, or absent,
/// and whatever else the test puts at other addresses.
class _Lan {
  /// How long the server takes to answer; null never answers at all.
  Duration? answerAfter = Duration.zero;

  /// Whether the server's address accepts a connection.
  bool accepts = true;

  /// Hosts a probe was sent to, in order.
  final List<String> probed = [];

  late final MockClient client = MockClient((request) async {
    probed.add(request.url.host);
    if (request.url.host != '192.168.1.10') {
      throw http.ClientException('Connection refused', request.url);
    }
    final delay = answerAfter;
    if (delay == null) {
      return Completer<http.Response>().future;
    }
    await Future<void>.delayed(delay);
    return http.Response(
      jsonEncode({
        'service': 'pointy-backend',
        'api_base_url': _server,
        'installation_id': 'installation-1',
        'shop_name': 'متجر آمن',
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });

  Future<bool> presence(Uri url, {Duration timeout = _brisk}) async =>
      url.host == '192.168.1.10' && accepts;
}

BackendDiscoveryService _discovery(
  _Lan lan, {
  List<String> ownAddresses = const ['192.168.1.50'],
  UdpDiscovery? udp,
  ServerPresenceProbe? presence,
  Duration manualProbeTimeout = const Duration(seconds: 5),
}) {
  return BackendDiscoveryService(
    client: lan.client,
    defaultApiBaseUrl: 'http://127.0.0.1:8000/api',
    probeTimeout: _brisk,
    patientProbeTimeout: _patient,
    udpTimeout: _udp,
    awayUdpTimeout: _awayUdp,
    manualProbeTimeout: manualProbeTimeout,
    udpDiscovery: udp ?? _silentUdp,
    subnetSweep: ({String? expectedInstallationId}) async => const [],
    serverPresence: presence ?? lan.presence,
    readAddresses: () async => [
      for (final address in ownAddresses)
        (interfaceName: 'en0', address: address),
    ],
  );
}

/// UDP that hears nothing and returns at once.
Future<List<Uri>> _silentUdp({Duration timeout = _udp}) async => const [];

Future<(PointyBackendEndpoint?, Duration)> _timed(
  Future<PointyBackendEndpoint?> Function() discover,
) async {
  final stopwatch = Stopwatch()..start();
  final endpoint = await discover();
  return (endpoint, stopwatch.elapsed);
}

void main() {
  group('a candidate that has not answered yet', () {
    // The till next to its server lost every race to a slow first answer — a
    // busy backend, or Windows' port forward into the WSL VM — and went out
    // over the internet for a server a few metres away.
    test('is waited for when its address accepts connections', () async {
      final lan = _Lan()..answerAfter = const Duration(milliseconds: 250);

      final (endpoint, elapsed) = await _timed(
        () => _discovery(lan).discover(
          preferredApiBaseUrls: const [_server],
          expectedInstallationId: 'installation-1',
        ),
      );

      expect(endpoint?.apiBaseUrl, _server);
      expect(elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 250)));
    });

    // A phone at home: its saved shop address leads nowhere, and nothing
    // there accepts a connection. It must reach the relay as quickly as it
    // always did.
    test('is dropped at the short deadline when nothing is there', () async {
      final lan = _Lan()
        ..accepts = false
        ..answerAfter = const Duration(milliseconds: 250);

      final (endpoint, elapsed) = await _timed(
        () => _discovery(lan).discover(
          preferredApiBaseUrls: const [_server],
          expectedInstallationId: 'installation-1',
        ),
      );

      expect(endpoint, isNull);
      expect(elapsed, lessThan(const Duration(milliseconds: 220)));
    });

    test(
      'is given up on at the patient deadline when it never answers',
      () async {
        final lan = _Lan()..answerAfter = null;

        final (endpoint, elapsed) = await _timed(
          () => _discovery(lan).discover(
            preferredApiBaseUrls: const [_server],
            expectedInstallationId: 'installation-1',
          ),
        );

        expect(endpoint, isNull);
        expect(elapsed, greaterThanOrEqualTo(_patient));
        expect(elapsed, lessThan(_patient + const Duration(milliseconds: 400)));
      },
    );

    test('a presence probe that throws counts as nothing there', () async {
      final lan = _Lan()..answerAfter = const Duration(milliseconds: 250);

      final endpoint = await _discovery(
        lan,
        presence: (url, {timeout = _brisk}) async =>
            throw StateError('no sockets here'),
      ).discover(preferredApiBaseUrls: const [_server]);

      expect(endpoint, isNull);
    });
  });

  test('a refused address ends its runner at once', () async {
    final lan = _Lan();

    final (endpoint, elapsed) = await _timed(
      () => _discovery(lan).discover(
        preferredApiBaseUrls: const ['http://192.168.1.99:8000/api'],
        expectedInstallationId: 'installation-1',
      ),
    );

    expect(endpoint, isNull);
    expect(elapsed, lessThan(_brisk), reason: 'nothing waited on the race');
  });

  test('a server UDP found is given the same patience', () async {
    // The stored address is stale; broadcast finds the server at its new one,
    // which then answers slowly.
    final lan = _Lan()..answerAfter = const Duration(milliseconds: 250);

    final endpoint = await _discovery(
      lan,
      udp: ({Duration timeout = _udp}) async => [Uri.parse(_server)],
    ).discover(preferredApiBaseUrls: const ['http://192.168.1.99:8000/api']);

    expect(endpoint?.apiBaseUrl, _server);
  });

  group('how long broadcast listens', () {
    Future<Duration?> listenedFor({
      required List<String> stored,
      required List<String> ownAddresses,
      bool addressesThrow = false,
    }) async {
      Duration? listened;
      final lan = _Lan()..accepts = false;
      final discovery = BackendDiscoveryService(
        client: lan.client,
        defaultApiBaseUrl: 'http://127.0.0.1:8000/api',
        probeTimeout: _brisk,
        patientProbeTimeout: _patient,
        udpTimeout: _udp,
        awayUdpTimeout: _awayUdp,
        udpDiscovery: ({Duration timeout = _udp}) async {
          listened = timeout;
          return const [];
        },
        subnetSweep: ({String? expectedInstallationId}) async => const [],
        serverPresence: lan.presence,
        readAddresses: () async {
          if (addressesThrow) {
            throw StateError('no interface list');
          }
          return [
            for (final address in ownAddresses)
              (interfaceName: 'wlan0', address: address),
          ];
        },
      );
      await discovery.discover(preferredApiBaseUrls: stored);
      return listened;
    }

    test('briefly on a network that is plainly not the shop\'s', () async {
      expect(
        await listenedFor(stored: const [_server], ownAddresses: ['10.0.0.5']),
        _awayUdp,
      );
    });

    test('in full on the network the server was found on', () async {
      expect(
        await listenedFor(
          stored: const [_server],
          ownAddresses: ['10.0.0.5', '192.168.1.77'],
        ),
        _udp,
      );
    });

    test('in full whenever where the device is cannot be told', () async {
      // The server is this machine.
      expect(
        await listenedFor(
          stored: const ['http://127.0.0.1:8000/api'],
          ownAddresses: ['10.0.0.5'],
        ),
        _udp,
      );
      // A name could be anywhere.
      expect(
        await listenedFor(
          stored: const ['http://pointy.shop:8000/api'],
          ownAddresses: ['10.0.0.5'],
        ),
        _udp,
      );
      // A fresh install has nowhere to be away from.
      expect(
        await listenedFor(stored: const [], ownAddresses: ['10.0.0.5']),
        _udp,
      );
      // No addresses known (a web build, an unreadable interface list).
      expect(
        await listenedFor(stored: const [_server], ownAddresses: const []),
        _udp,
      );
      expect(
        await listenedFor(
          stored: const [_server],
          ownAddresses: const ['10.0.0.5'],
          addressesThrow: true,
        ),
        _udp,
      );
    });
  });

  test('an address the operator typed is waited on in full', () async {
    // Nothing races it, so it gets the manual deadline whether or not the
    // address showed itself in time.
    final lan = _Lan()
      ..accepts = false
      ..answerAfter = const Duration(milliseconds: 250);

    final endpoint = await _discovery(
      lan,
      manualProbeTimeout: const Duration(seconds: 2),
    ).probe('192.168.1.10');

    expect(endpoint?.apiBaseUrl, _server);
  });

  test('the sweep\'s finds are probed like any other candidate', () async {
    final lan = _Lan()..answerAfter = const Duration(milliseconds: 250);
    final discovery = BackendDiscoveryService(
      client: lan.client,
      defaultApiBaseUrl: 'http://127.0.0.1:8000/api',
      probeTimeout: _brisk,
      patientProbeTimeout: _patient,
      udpTimeout: _udp,
      awayUdpTimeout: _awayUdp,
      udpDiscovery: _silentUdp,
      subnetSweep: ({String? expectedInstallationId}) async => [_server],
      serverPresence: lan.presence,
      readAddresses: () async => const <LanAddressCandidate>[],
    );

    final endpoint = await discovery.discover(includeSweep: true);

    expect(endpoint?.apiBaseUrl, _server);
  });
}
