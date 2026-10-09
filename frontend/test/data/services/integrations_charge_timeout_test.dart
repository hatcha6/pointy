import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/integrations_api_client.dart';

/// Performing a sale's provider lines waits for a supplier — the shop backend
/// itself waits up to 80 seconds for the relay — so the till's wait for that one
/// call must outlast it, or a charge that was in fact being performed is
/// reported as lost.
void main() {
  test('waits at least as long as the backend waits for the relay', () {
    expect(
      IntegrationsApiClient.chargeTimeout,
      greaterThanOrEqualTo(const Duration(seconds: 90)),
    );
  });

  test('is not cut short by the session\'s ordinary timeout', () async {
    final session = PosApiSession(
      client: MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return http.Response(
          jsonEncode({
            'results': [
              {'kind': 'airtime', 'outcome': 'charged', 'status': 'confirmed'},
            ],
            'balance': 506.37,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
      baseUrl: 'http://lan.test/api',
      requestTimeout: const Duration(milliseconds: 40),
    );

    final results = await IntegrationsApiClient(session).charge(orderId: 7);

    expect(results.single.isCharged, isTrue);
  });
}
