import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/models/clock_time.dart';
import 'package:pointy_frontend/src/data/models/messaging_gateway.dart';
import 'package:pointy_frontend/src/data/services/api_error_detail.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/messaging_api_client.dart';

const _lan = 'http://lan.test/api';

http.Response _json(Object body, int statusCode) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

const _gateway = {
  'id': 4,
  'name': 'رسائل دفتر',
  'provider': 'relay',
  'is_default': true,
  'is_active': false,
  'max_messages_per_minute': 12,
  'daily_cap': 150,
  'quiet_hours_start': null,
  'quiet_hours_end': null,
};

void main() {
  test('reads the status from /messaging/status/', () async {
    final seen = <http.Request>[];
    final client = MessagingApiClient(
      PosApiSession(
        client: MockClient((request) async {
          seen.add(request);
          return _json({
            'entitled': true,
            'available': false,
            'test_mode': true,
            'gateway': _gateway,
            'usage': null,
            'usage_error': 'relay_unreachable',
            'templates': const [],
          }, 200);
        }),
        baseUrl: _lan,
      ),
    );

    final status = await client.fetchStatus();

    expect(seen.single.method, 'GET');
    expect(seen.single.url.path, '/api/messaging/status/');
    expect(status.testMode, isTrue);
    expect(status.gateway?.isActive, isFalse);
    expect(status.isRelayUnreachable, isTrue);
  });

  test('saves the dials with a PATCH of the editable fields only', () async {
    final seen = <http.Request>[];
    final client = MessagingApiClient(
      PosApiSession(
        client: MockClient((request) async {
          seen.add(request);
          return _json(_gateway, 200);
        }),
        baseUrl: _lan,
      ),
    );

    final saved = await client.updateGateway(
      4,
      const MessagingGatewayUpdate(
        isActive: false,
        maxMessagesPerMinute: 12,
        dailyCap: 150,
        quietHoursStart: ClockTime(23, 0),
        quietHoursEnd: ClockTime(7, 30),
      ),
    );

    final request = seen.single;
    expect(request.method, 'PATCH');
    expect(request.url.path, '/api/messaging/gateways/4/');
    expect(jsonDecode(request.body), {
      'is_active': false,
      'max_messages_per_minute': 12,
      'daily_cap': 150,
      'quiet_hours_start': '23:00:00',
      'quiet_hours_end': '07:30:00',
    });
    expect(saved.dailyCap, 150);
  });

  test('a test send posts the number and nothing else', () async {
    final seen = <http.Request>[];
    final client = MessagingApiClient(
      PosApiSession(
        client: MockClient((request) async {
          seen.add(request);
          return _json({
            'status': 'sent',
            'error_code': '',
            'error_detail': '',
            'body': 'رسالة تجريبية من محل النور عبر دفتر',
            'template_kind': 'test',
          }, 200);
        }),
        baseUrl: _lan,
      ),
    );

    final result = await client.testSend(id: 4, to: '0912345678');

    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/api/messaging/gateways/4/test_send/');
    expect(jsonDecode(seen.single.body), {'to': '0912345678'});
    expect(result.ok, isTrue);
    expect(result.body, contains('محل النور'));
  });

  test('a refusal keeps its code for the page to name', () async {
    final client = MessagingApiClient(
      PosApiSession(
        client: MockClient(
          (request) async => _json({
            'detail': 'خدمة الرسائل غير مفعّلة في اشتراك المحل.',
            'code': 'not_entitled',
          }, 400),
        ),
        baseUrl: _lan,
      ),
    );

    Object? error;
    try {
      await client.testSend(id: 4, to: '0912345678');
    } catch (caught) {
      error = caught;
    }

    expect(error, isA<PosApiException>());
    expect(apiErrorCode(error), 'not_entitled');
    expect(apiErrorDetail(error), contains('اشتراك المحل'));
  });
}
