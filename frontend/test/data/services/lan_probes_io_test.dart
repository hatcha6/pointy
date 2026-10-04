// The socket-level probes discovery leans on, against real sockets on this
// machine's loopback only — nothing leaves it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/pos_http_client_io.dart';
import 'package:pointy_frontend/src/data/services/server_presence_io.dart';
import 'package:pointy_frontend/src/data/services/subnet_sweep_io.dart';

/// A loopback port that was just free and now refuses connections.
Future<int> _closedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// Real HTTP for the duration of a test. The Flutter test binding answers
/// every `HttpClient` request with a 400 of its own, which would hide what a
/// real server on loopback says.
void _useRealHttp() {
  final previous = HttpOverrides.current;
  HttpOverrides.global = null;
  addTearDown(() => HttpOverrides.global = previous);
}

void main() {
  group('probeServerPresence', () {
    test('something listening is there', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) => socket.destroy());

      expect(
        await probeServerPresence(
          Uri.parse('http://127.0.0.1:${server.port}/api/discovery/service/'),
        ),
        isTrue,
      );
    });

    test('a port nothing listens on is not', () async {
      final port = await _closedPort();

      expect(
        await probeServerPresence(Uri.parse('http://127.0.0.1:$port/api/')),
        isFalse,
      );
    });

    test('no host is not', () async {
      expect(await probeServerPresence(Uri.parse('/api/')), isFalse);
    });
  });

  group('a host the sweep asks', () {
    late HttpServer server;
    Duration answerAfter = Duration.zero;
    String installationId = 'installation-1';

    setUp(() async {
      _useRealHttp();
      answerAfter = Duration.zero;
      installationId = 'installation-1';
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await Future<void>.delayed(answerAfter);
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'service': 'pointy-backend',
              'api_base_url': 'http://127.0.0.1:${server.port}/api',
              'installation_id': installationId,
            }),
          );
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    Future<String?> ask({
      Duration connectTimeout = const Duration(milliseconds: 200),
      Duration answerTimeout = const Duration(seconds: 2),
      String expected = 'installation-1',
    }) async {
      final client = HttpClient()..connectionTimeout = connectTimeout;
      addTearDown(() => client.close(force: true));
      return probeHostForBackend(
        client,
        '127.0.0.1',
        server.port,
        connectTimeout: connectTimeout,
        answerTimeout: answerTimeout,
        expectedInstallationId: expected,
      );
    }

    // The sweep gives an empty address a fraction of a second, which used to
    // be all a busy server got too.
    test('is given longer to answer than to accept', () async {
      answerAfter = const Duration(milliseconds: 400);

      expect(await ask(), 'http://127.0.0.1:${server.port}/api');
    });

    test('is dropped once its answer runs past the answer deadline', () async {
      answerAfter = const Duration(milliseconds: 400);

      expect(
        await ask(answerTimeout: const Duration(milliseconds: 100)),
        isNull,
      );
    });

    test("another shop's server is not ours", () async {
      installationId = 'installation-other';

      expect(await ask(), isNull);
    });

    test('a port nothing listens on is passed over', () async {
      final port = await _closedPort();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      expect(
        await probeHostForBackend(
          client,
          '127.0.0.1',
          port,
          connectTimeout: const Duration(milliseconds: 200),
          answerTimeout: const Duration(seconds: 1),
        ),
        isNull,
      );
    });
  });

  group('LanAwareHttpClient', () {
    test('sends the shop network through the LAN client, the rest through '
        'the internet one', () async {
      final viaLan = <String>[];
      final viaInternet = <String>[];
      final client = LanAwareHttpClient.withClients(
        lan: MockClient((request) async {
          viaLan.add(request.url.host);
          return http.Response('', 200);
        }),
        internet: MockClient((request) async {
          viaInternet.add(request.url.host);
          return http.Response('', 200);
        }),
      );
      addTearDown(client.close);

      for (final url in [
        'http://192.168.1.10:8000/api/products/',
        'http://10.0.0.5:8000/api/',
        'http://127.0.0.1:8000/api/',
        'http://localhost:8000/api/',
        'https://relay.pointy.ly/api/products/',
        'https://8.8.8.8/',
      ]) {
        await client.get(Uri.parse(url));
      }

      expect(viaLan, ['192.168.1.10', '10.0.0.5', '127.0.0.1', 'localhost']);
      expect(viaInternet, ['relay.pointy.ly', '8.8.8.8']);
    });

    test('a real one reaches a server on this machine', () async {
      _useRealHttp();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write('ok');
        await request.response.close();
      });
      final client = LanAwareHttpClient();
      addTearDown(client.close);

      final response = await client.get(
        Uri.parse('http://127.0.0.1:${server.port}/'),
      );

      expect(response.body, 'ok');
    });
  });
}
