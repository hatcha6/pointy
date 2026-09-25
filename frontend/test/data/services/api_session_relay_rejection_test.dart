import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';

const _relay = 'https://relay.test/api';
const _ticketHeader = 'X-Pointy-Relay-Token';

http.Response _relayRefusal({
  int statusCode = 401,
  String error = 'relay token rejected',
}) {
  return http.Response(
    jsonEncode({'error': error}),
    statusCode,
    headers: {'content-type': 'application/json'},
  );
}

http.Response _backendSignedOut() {
  return http.Response(
    jsonEncode({'detail': 'Authentication credentials were not provided.'}),
    401,
    headers: {'content-type': 'application/json'},
  );
}

/// A relay that refuses `ptt1.old` and answers anything else.
PosApiSession _sessionOnRelay({
  required List<String?> ticketsSeen,
  http.Response Function()? refusal,
}) {
  return PosApiSession(
    client: MockClient((request) async {
      final ticket = request.headers[_ticketHeader];
      ticketsSeen.add(ticket);
      if (ticket == 'ptt1.old') {
        return (refusal ?? _relayRefusal)();
      }
      return http.Response('{"ok":true}', 200);
    }),
    baseUrl: _relay,
  )..configureConnectionTarget(baseUrl: _relay, relayToken: 'ptt1.old');
}

void main() {
  group('a ticket the relay refuses', () {
    test(
      'is replaced once and the request sent again with the new one',
      () async {
        final tickets = <String?>[];
        final session = _sessionOnRelay(ticketsSeen: tickets);
        var refreshes = 0;
        session.onRelayTicketRejected = () async {
          refreshes++;
          session.configureConnectionTarget(
            baseUrl: _relay,
            relayToken: 'ptt1.new',
          );
          return RelayTicketRecovery.refreshed;
        };

        final response = await session.get('products/');

        expect(response.statusCode, 200);
        expect(tickets, ['ptt1.old', 'ptt1.new']);
        expect(refreshes, 1);
        expect(session.usesRelay, isTrue);
      },
    );

    // The relay refuses before it forwards, so nothing reached the backend:
    // a repeat is safe for a write too, keyed or not.
    test('a write is sent again as well', () async {
      final tickets = <String?>[];
      final session = _sessionOnRelay(ticketsSeen: tickets);
      session.onRelayTicketRejected = () async {
        session.configureConnectionTarget(
          baseUrl: _relay,
          relayToken: 'ptt1.new',
        );
        return RelayTicketRecovery.refreshed;
      };

      final response = await session.post(
        'inventory/adjustments/',
        body: {'quantity': 1},
      );

      expect(response.statusCode, 200);
      expect(tickets, ['ptt1.old', 'ptt1.new']);
    });

    test('is given up on when no new ticket could be minted', () async {
      final tickets = <String?>[];
      final session = _sessionOnRelay(ticketsSeen: tickets);
      session.onRelayTicketRejected = () async => RelayTicketRecovery.failed;

      final response = await session.get('products/');

      expect(response.statusCode, 401);
      expect(relayErrorOf(response), 'relay token rejected');
      expect(tickets, ['ptt1.old']);
    });

    // The relay refused the ticket, and then refused the device's refresh
    // for a lapsed subscription. That second answer is the true one: the
    // request is answered with it, so the screen can name the subscription
    // rather than a lost ticket.
    test('a subscription found lapsed at the refresh is the answer', () async {
      final tickets = <String?>[];
      final session = _sessionOnRelay(ticketsSeen: tickets);
      session.onRelayTicketRejected = () async =>
          RelayTicketRecovery.subscriptionInactive;

      final response = await session.get('products/');

      expect(response.statusCode, 402);
      expect(relayErrorOf(response), 'relay subscription inactive');
      expect(tickets, ['ptt1.old']);
    });

    test('is given up on when nothing is wired to mint one', () async {
      final tickets = <String?>[];
      final session = _sessionOnRelay(ticketsSeen: tickets);

      final response = await session.get('products/');

      expect(response.statusCode, 401);
      expect(tickets, ['ptt1.old']);
    });

    // The 401 belongs to a ticket that a scheduled refresh (or another
    // request's recovery) already replaced while this request was in flight.
    test(
      'a newer ticket already installed is used without another refresh',
      () async {
        final tickets = <String?>[];
        late PosApiSession session;
        session = PosApiSession(
          client: MockClient((request) async {
            final ticket = request.headers[_ticketHeader];
            tickets.add(ticket);
            if (ticket == 'ptt1.old') {
              session.configureConnectionTarget(
                baseUrl: _relay,
                relayToken: 'ptt1.new',
              );
              return _relayRefusal();
            }
            return http.Response('{"ok":true}', 200);
          }),
          baseUrl: _relay,
        )..configureConnectionTarget(baseUrl: _relay, relayToken: 'ptt1.old');
        var refreshes = 0;
        session.onRelayTicketRejected = () async {
          refreshes++;
          return RelayTicketRecovery.refreshed;
        };

        final response = await session.get('products/');

        expect(response.statusCode, 200);
        expect(tickets, ['ptt1.old', 'ptt1.new']);
        expect(refreshes, 0);
      },
    );

    test("the backend's own 401 is a sign-out, not a ticket problem", () async {
      final tickets = <String?>[];
      final session = _sessionOnRelay(
        ticketsSeen: tickets,
        refusal: _backendSignedOut,
      );
      var refreshes = 0;
      session.onRelayTicketRejected = () async {
        refreshes++;
        return RelayTicketRecovery.refreshed;
      };

      final response = await session.get('auth/me/');

      expect(response.statusCode, 401);
      expect(relayErrorOf(response), isNull);
      expect(refreshes, 0);
      expect(tickets, ['ptt1.old']);
    });

    test(
      'a lapsed subscription is not something a new ticket would fix',
      () async {
        final tickets = <String?>[];
        final session = _sessionOnRelay(
          ticketsSeen: tickets,
          refusal: () => _relayRefusal(
            statusCode: 402,
            error: 'relay subscription inactive',
          ),
        );
        var refreshes = 0;
        session.onRelayTicketRejected = () async {
          refreshes++;
          return RelayTicketRecovery.refreshed;
        };

        final response = await session.get('products/');

        expect(response.statusCode, 402);
        expect(refreshes, 0);
        expect(tickets, ['ptt1.old']);
      },
    );

    test(
      'a session on the LAN carries no ticket and never asks for one',
      () async {
        var refreshes = 0;
        final session =
            PosApiSession(
                client: MockClient((request) async => _relayRefusal()),
                baseUrl: 'http://lan.test/api',
              )
              ..onRelayTicketRejected = () async {
                refreshes++;
                return RelayTicketRecovery.refreshed;
              };

        final response = await session.get('products/');

        expect(response.statusCode, 401);
        expect(refreshes, 0);
      },
    );
  });

  group('telling the relay from the backend', () {
    test(
      'the relay names its refusal under error, the backend under detail',
      () {
        expect(relayErrorOf(_relayRefusal()), 'relay token rejected');
        expect(isRelayTicketRejection(_relayRefusal()), isTrue);
        expect(relayErrorOf(_backendSignedOut()), isNull);
        expect(isRelayTicketRejection(_backendSignedOut()), isFalse);
        expect(
          relayErrorOf(http.Response('<html>bad gateway</html>', 502)),
          isNull,
        );
        expect(relayErrorOf(http.Response('{"error":"x"}', 200)), isNull);
      },
    );

    test('an exception thrown for a relay answer says so', () {
      final session = PosApiSession(
        client: MockClient((_) async => http.Response('', 500)),
        baseUrl: _relay,
      );

      PosApiException? fromRelay;
      try {
        session.throwApiException(
          _relayRefusal(
            statusCode: 503,
            error: 'installation connector offline',
          ),
          'Login failed with status',
        );
      } on PosApiException catch (exception) {
        fromRelay = exception;
      }
      PosApiException? fromBackend;
      try {
        session.throwApiException(
          _backendSignedOut(),
          'Login failed with status',
        );
      } on PosApiException catch (exception) {
        fromBackend = exception;
      }

      expect(fromRelay?.fromRelay, isTrue);
      expect(fromRelay?.statusCode, 503);
      expect(fromBackend?.fromRelay, isFalse);
    });
  });
}
