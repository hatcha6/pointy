import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';

void main() {
  test('API session records successful request performance', () async {
    final timings = <ApiRequestPerformance>[];
    final session = PosApiSession(
      client: MockClient((request) async => http.Response('{"ok":true}', 200)),
      baseUrl: 'http://pointy.test/api',
    )..performanceRecorder = timings.add;

    await session.post('orders/checkout/', body: {'lines': []});

    expect(timings, hasLength(1));
    expect(timings.single.method, 'POST');
    expect(timings.single.path, 'orders/checkout/');
    expect(timings.single.statusCode, 200);
    expect(timings.single.requestSizeBytes, greaterThan(0));
    expect(timings.single.responseSizeBytes, greaterThan(0));
  });

  test(
    'API session records network failures without swallowing them',
    () async {
      final timings = <ApiRequestPerformance>[];
      final session = PosApiSession(
        client: MockClient((request) async => throw Exception('offline')),
        baseUrl: 'http://pointy.test/api',
      )..performanceRecorder = timings.add;

      await expectLater(session.get('products/'), throwsException);

      expect(timings, hasLength(1));
      expect(timings.single.method, 'GET');
      expect(timings.single.path, 'products/');
      expect(timings.single.statusCode, isNull);
      expect(timings.single.failed, isTrue);
      expect(timings.single.errorMessage, contains('offline'));
    },
  );

  test(
    'API session skips analytics ingest performance to avoid feedback loops',
    () async {
      final timings = <ApiRequestPerformance>[];
      final session = PosApiSession(
        client: MockClient(
          (request) async => http.Response('{"accepted":0}', 201),
        ),
        baseUrl: 'http://pointy.test/api',
      )..performanceRecorder = timings.add;

      await session.post('analytics-events/ingest/', body: {'events': []});

      expect(timings, isEmpty);
    },
  );

  test(
    'API session retries once with relay fallback on network failure',
    () async {
      final session = PosApiSession(
        client: MockClient((request) async {
          if (request.url.host == 'lan.test') {
            throw Exception('lan offline');
          }
          expect(request.url.toString(), 'https://relay.test/api/products/');
          expect(request.headers['X-Pointy-Relay-Token'], 'ptt1.ticket');
          return http.Response('{"ok":true}', 200);
        }),
        baseUrl: 'http://lan.test/api',
      );
      session.configureConnectionTarget(
        baseUrl: 'http://lan.test/api',
        fallbackTarget: const ApiConnectionTarget(
          baseUrl: 'https://relay.test/api',
          relayToken: 'ptt1.ticket',
        ),
      );

      final response = await session.get('products/');

      expect(response.statusCode, 200);
      expect(session.baseUrl, 'https://relay.test/api');
      expect(session.usesRelay, isTrue);
    },
  );
}
