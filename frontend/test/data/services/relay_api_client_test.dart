import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';

void main() {
  test('requestRelayPairing posts device metadata and parses ticket', () async {
    final service = PosApiService(
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), 'http://pointy.test/api/relay/pairing/');
        expect(jsonDecode(request.body), {
          'device_id': 'phone-1',
          'device_name': 'هاتف المدير',
        });
        return http.Response(
          jsonEncode({
            'remote_access_supported': true,
            'installation_id': 'installation-1',
            'shop_name': 'متجر آمن',
            'relay_public_api_url': 'https://relay.example',
            'relay_token': 'ptt1.installation-1.ticket-secret',
            'expires_at': '2026-06-02T12:15:00Z',
            'reason': '',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      baseUrl: 'http://pointy.test/api',
    );

    final pairing = await service.requestRelayPairing(
      deviceId: 'phone-1',
      deviceName: 'هاتف المدير',
    );

    expect(pairing.hasTicket, isTrue);
    expect(pairing.installationId, 'installation-1');
    expect(pairing.shopName, 'متجر آمن');
    expect(pairing.relayPublicApiUrl, 'https://relay.example');
    expect(pairing.relayToken, 'ptt1.installation-1.ticket-secret');
    expect(pairing.expiresAt?.toUtc(), DateTime.utc(2026, 6, 2, 12, 15));
  });

  test(
    'requestRelayPairing preserves inactive reason without a ticket',
    () async {
      final service = PosApiService(
        client: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'remote_access_supported': false,
              'installation_id': 'installation-1',
              'shop_name': 'متجر آمن',
              'relay_public_api_url': 'https://relay.example',
              'relay_token': '',
              'expires_at': null,
              'reason': 'relay_not_active',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        baseUrl: 'http://pointy.test/api',
      );

      final pairing = await service.requestRelayPairing();

      expect(pairing.hasTicket, isFalse);
      expect(pairing.reason, 'relay_not_active');
      expect(pairing.expiresAt, isNull);
    },
  );
}
