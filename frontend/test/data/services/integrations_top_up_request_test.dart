import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/integrations_api_client.dart';

/// What a float top-up puts on the wire. The server reads a missing source as
/// its default cash box, and reads outside money only from `from_outside`.
/// A request without either used to record money from nowhere.
void main() {
  Future<Map<String, Object?>> send({
    int? fromAccountId,
    bool fromOutside = false,
  }) async {
    final seen = <http.Request>[];
    final client = IntegrationsApiClient(
      PosApiSession(
        client: MockClient((request) async {
          seen.add(request);
          return http.Response(
            jsonEncode({'expected_balance': '100.00', 'topped_up': '100.00'}),
            201,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
        baseUrl: 'http://lan.test/api',
      ),
    );

    await client.recordTopUp(
      'lnet',
      amount: 100,
      fromAccountId: fromAccountId,
      fromOutside: fromOutside,
      reference: '8891',
    );

    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/api/integrations/lnet/float/');
    return jsonDecode(seen.single.body) as Map<String, Object?>;
  }

  test('a chosen cash box or bank is sent by id', () async {
    expect(await send(fromAccountId: 3), {
      'amount': '100.00',
      'from_account': 3,
      'reference': '8891',
    });
  });

  test('money from outside the shop is said explicitly', () async {
    final body = await send(fromOutside: true);

    expect(body['from_outside'], isTrue);
    expect(body.containsKey('from_account'), isFalse);
  });

  test('no source leaves the choice to the server', () async {
    final body = await send();

    expect(body.containsKey('from_account'), isFalse);
    expect(body.containsKey('from_outside'), isFalse);
  });
}
