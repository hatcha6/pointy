import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';

/// A backend that completed the TCP handshake and then went silent: every
/// request is accepted and simply never answered. This is what a wedged
/// uvicorn, an AP roam that stranded a pooled connection, or a LAN that starts
/// dropping packets after the handshake looks like from the client — the
/// socket never errors, so no `catch` in the app ever runs.
MockClient _blackHole({void Function()? onRequest}) {
  return MockClient((request) {
    onRequest?.call();
    return Completer<http.Response>().future;
  });
}

void main() {
  const short = Duration(milliseconds: 40);
  const testBound = Duration(seconds: 3);

  test('a silently hung request fails instead of waiting forever', () async {
    final session = PosApiSession(
      client: _blackHole(),
      baseUrl: 'http://pointy.test/api',
      requestTimeout: short,
    );

    await expectLater(
      session.post('orders/checkout/', body: {'lines': []}),
      throwsA(isA<TimeoutException>()),
    ).timeout(testBound);
  });

  test('a hung LAN request still triggers backend re-discovery', () async {
    var unreachable = 0;
    final session = PosApiSession(
      client: _blackHole(),
      baseUrl: 'http://pointy.test/api',
      requestTimeout: short,
    )..onLocalTargetUnreachable = () => unreachable++;

    await expectLater(
      session.get('products/'),
      throwsA(isA<TimeoutException>()),
    ).timeout(testBound);

    expect(unreachable, 1);
  });

  test('a hung request is recorded as a failed timing', () async {
    final timings = <ApiRequestPerformance>[];
    final session = PosApiSession(
      client: _blackHole(),
      baseUrl: 'http://pointy.test/api',
      requestTimeout: short,
    )..performanceRecorder = timings.add;

    await expectLater(
      session.get('products/'),
      throwsA(isA<TimeoutException>()),
    ).timeout(testBound);

    expect(timings, hasLength(1));
    expect(timings.single.failed, isTrue);
    expect(timings.single.errorMessage, contains('TimeoutException'));
  });

  // A LAN request that times out reached a backend that is slow far more
  // often than one that is gone — and the relay leads to that same backend.
  // Replaying there used to double the wait, add load to a struggling server,
  // and leave the till on the internet path for the rest of the day. The
  // coordinator hears about it instead and decides after its own look.
  test('a hung read is not replayed on the relay', () async {
    var attempts = 0;
    var unreachable = 0;
    final session =
        PosApiSession(
            client: MockClient((request) {
              attempts++;
              if (request.url.host == 'pointy.test') {
                return Completer<http.Response>().future;
              }
              return Future.value(http.Response('{"ok":true}', 200));
            }),
            baseUrl: 'http://pointy.test/api',
            requestTimeout: short,
          )
          ..configureConnectionTarget(
            baseUrl: 'http://pointy.test/api',
            fallbackTarget: const ApiConnectionTarget(
              baseUrl: 'https://relay.test/api',
              relayToken: 'token',
            ),
          )
          ..onLocalTargetUnreachable = () => unreachable++;

    await expectLater(
      session.get('products/'),
      throwsA(isA<TimeoutException>()),
    ).timeout(testBound);

    expect(attempts, 1);
    expect(session.usesRelay, isFalse);
    expect(session.baseUrl, 'http://pointy.test/api');
    expect(unreachable, 1);
  });

  test(
    'a hung write with no idempotency key is never replayed on the fallback',
    () async {
      var attempts = 0;
      final session =
          PosApiSession(
            client: _blackHole(onRequest: () => attempts++),
            baseUrl: 'http://pointy.test/api',
            requestTimeout: short,
          )..configureConnectionTarget(
            baseUrl: 'http://pointy.test/api',
            fallbackTarget: const ApiConnectionTarget(
              baseUrl: 'https://relay.test/api',
              relayToken: 'token',
            ),
          );

      await expectLater(
        session.post('orders/checkout/', body: {'lines': []}),
        throwsA(isA<TimeoutException>()),
      ).timeout(testBound);

      expect(attempts, 1);
    },
  );

  test(
    'a hung write is not replayed on the relay even with an idempotency key',
    () async {
      var attempts = 0;
      final session =
          PosApiSession(
            client: MockClient((request) {
              attempts++;
              if (request.url.host == 'pointy.test') {
                return Completer<http.Response>().future;
              }
              return Future.value(http.Response('{"ok":true}', 201));
            }),
            baseUrl: 'http://pointy.test/api',
            requestTimeout: short,
          )..configureConnectionTarget(
            baseUrl: 'http://pointy.test/api',
            fallbackTarget: const ApiConnectionTarget(
              baseUrl: 'https://relay.test/api',
              relayToken: 'token',
            ),
          );

      await expectLater(
        session.post(
          'orders/checkout/',
          body: {'lines': []},
          idempotencyKey: 'checkout:1',
        ),
        throwsA(isA<TimeoutException>()),
      ).timeout(testBound);

      expect(attempts, 1);
      expect(session.usesRelay, isFalse);
    },
  );

  test('a long-running request may outlive the default deadline', () async {
    final session = PosApiSession(
      client: MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        return http.Response('{"ok":true}', 200);
      }),
      baseUrl: 'http://pointy.test/api',
      requestTimeout: short,
    );

    final response = await session
        .post('backup/', timeout: const Duration(seconds: 2))
        .timeout(testBound);

    expect(response.statusCode, 200);
  });
}
