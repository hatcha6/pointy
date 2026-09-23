import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/companion.dart';
import 'package:pointy_frontend/src/data/repositories/companion_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';

/// A backend that builds the QR from the address the till reached it on — as
/// the real one does.
CompanionRepository _repository({required String backendUrl}) {
  final client = MockClient((request) async {
    expect(request.url.path, endsWith('/companion/pairings/'));
    return http.Response(
      jsonEncode({
        'code': 'ABCD-2345',
        'url': '$backendUrl/c/#ABCD-2345',
        'till_key': 'till-1',
        'expires_at': '2030-01-01T00:00:00Z',
      }),
      201,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  return CompanionRepository(
    PosApiService(client: client, baseUrl: '$backendUrl/api'),
    // The server PC of a WSL install: WSL's adapter shares the LAN's range.
    readAddresses: () async => [
      (interfaceName: 'vEthernet (WSL)', address: '192.168.176.1'),
      (interfaceName: 'Ethernet', address: '192.168.1.20'),
    ],
  );
}

Future<CompanionPairing> _pair(CompanionRepository repository) async {
  final result = await repository.createPairing(tillKey: 'till-1');
  return (result as Ok<CompanionPairing>).value;
}

void main() {
  test('a till on the server PC shows a QR the phone can open', () async {
    // The bug: this till reaches the backend over loopback, the backend built
    // the QR from that, and the phone that scanned it tried to open itself.
    final pairing = await _pair(
      _repository(backendUrl: 'http://127.0.0.1:8000'),
    );

    expect(pairing.url, 'http://192.168.1.20:8000/c/#ABCD-2345');
    expect(pairing.code, 'ABCD-2345');
  });

  test('a till elsewhere on the LAN keeps the address it proved', () async {
    final pairing = await _pair(
      _repository(backendUrl: 'http://192.168.1.5:8000'),
    );

    expect(pairing.url, 'http://192.168.1.5:8000/c/#ABCD-2345');
  });
}
