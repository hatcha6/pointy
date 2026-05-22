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
}
