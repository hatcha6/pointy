import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';

const _lan = 'http://lan.test/api';
const _relay = 'https://relay.test/api';

/// A LAN that resets every connection and a relay that answers.
///
/// The reset is the kind of failure that can arrive AFTER the request reached
/// the server, which is why only a request the server can recognise a second
/// time may be replayed on the relay.
PosApiSession _sessionOnFlakyLan({
  required List<String> hosts,
  void Function()? onUnreachable,
}) {
  final session =
      PosApiSession(
        client: MockClient((request) async {
          hosts.add(request.url.host);
          if (request.url.host == 'lan.test') {
            throw http.ClientException('Connection reset by peer');
          }
          return http.Response('{"ok":true}', 201);
        }),
        baseUrl: _lan,
      )..configureConnectionTarget(
        baseUrl: _lan,
        fallbackTarget: const ApiConnectionTarget(
          baseUrl: _relay,
          relayToken: 'ptt1.ticket',
        ),
      );
  if (onUnreachable != null) {
    session.onLocalTargetUnreachable = onUnreachable;
  }
  return session;
}

void main() {
  group('replaying a failed LAN request on the relay', () {
    test(
      'a keyed write is replayed and the session reports it moved',
      () async {
        final hosts = <String>[];
        var unreachable = 0;
        final session = _sessionOnFlakyLan(
          hosts: hosts,
          onUnreachable: () => unreachable++,
        );

        final response = await session.post(
          'orders/checkout/',
          body: {'lines': []},
          idempotencyKey: 'checkout:7',
        );

        expect(response.statusCode, 201);
        expect(hosts, ['lan.test', 'relay.test']);
        expect(session.usesRelay, isTrue);
        expect(unreachable, 1);
      },
    );

    test('a write without an idempotency key is never replayed', () async {
      final hosts = <String>[];
      var unreachable = 0;
      final session = _sessionOnFlakyLan(
        hosts: hosts,
        onUnreachable: () => unreachable++,
      );

      await expectLater(
        session.post('inventory/adjustments/', body: {'quantity': 1}),
        throwsA(isA<http.ClientException>()),
      );

      // Reset or not, the server may have recorded it: the cashier decides.
      expect(hosts, ['lan.test']);
      expect(session.usesRelay, isFalse);
      expect(unreachable, 1);
    });

    test('a byte upload is never replayed', () async {
      final hosts = <String>[];
      final session = _sessionOnFlakyLan(hosts: hosts);

      await expectLater(
        session.putBytes(
          'migration/uploads/1/chunk/',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
        throwsA(isA<http.ClientException>()),
      );

      expect(hosts, ['lan.test']);
      expect(session.usesRelay, isFalse);
    });

    test('a failure on the relay itself is not a LAN failure', () async {
      var unreachable = 0;
      final session =
          PosApiSession(
              client: MockClient((request) async {
                throw http.ClientException('Network is unreachable');
              }),
              baseUrl: _relay,
            )
            ..configureConnectionTarget(
              baseUrl: _relay,
              relayToken: 'ptt1.ticket',
            )
            ..onLocalTargetUnreachable = () => unreachable++;

      await expectLater(
        session.get('products/'),
        throwsA(isA<http.ClientException>()),
      );

      expect(unreachable, 0);
    });
  });

  group('what re-pointing the session keeps', () {
    late List<String?> sentIfNoneMatch;
    late PosApiSession session;

    setUp(() {
      sentIfNoneMatch = [];
      session = PosApiSession(
        client: MockClient((request) async {
          sentIfNoneMatch.add(request.headers['If-None-Match']);
          const etag = 'W/"catalog-v1"';
          if (request.headers['If-None-Match'] == etag) {
            return http.Response('', 304, headers: {'etag': etag});
          }
          return http.Response(
            '{"results":[]}',
            200,
            headers: {'etag': etag, 'x-pointy-state': 'catalog_defs=4'},
          );
        }),
        baseUrl: _lan,
      );
    });

    Future<void> warm() async {
      await session.get('products/', conditionalCache: true);
      expect(session.serverState.versionOf('catalog_defs'), '4');
    }

    // A rediscovery that re-finds the LAN server the session already uses, or
    // a refreshed relay ticket, re-points the session at the same address.
    // Dropping the cache there turned each of those into a full re-download of
    // every screen for nothing.
    test('the same address keeps cached bodies and counters', () async {
      await warm();

      session.configureConnectionTarget(
        baseUrl: '$_lan/',
        fallbackTarget: const ApiConnectionTarget(
          baseUrl: _relay,
          relayToken: 'ptt1.new-ticket',
        ),
      );
      await session.get('products/', conditionalCache: true);

      expect(sentIfNoneMatch.last, 'W/"catalog-v1"');
      expect(session.serverState.versionOf('catalog_defs'), '4');
    });

    test('a different address starts from nothing', () async {
      await warm();

      session.configureConnectionTarget(baseUrl: 'http://other.lan/api');
      expect(session.serverState.versionOf('catalog_defs'), isNull);
      await session.get('products/', conditionalCache: true);

      expect(sentIfNoneMatch.last, isNull);
    });

    test(
      'forgetBackendState starts from nothing at the same address',
      () async {
        await warm();

        session.forgetBackendState();
        expect(session.serverState.versionOf('catalog_defs'), isNull);
        await session.get('products/', conditionalCache: true);

        expect(sentIfNoneMatch.last, isNull);
      },
    );
  });
}
