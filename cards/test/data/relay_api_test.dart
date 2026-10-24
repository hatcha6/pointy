import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/src/data/api/relay_api.dart';
import 'package:pointy_cards/src/data/session/session_store.dart';

const _session = CustomerSession(
  sessionId: 's1',
  customerId: 'c1',
  phone: '218912345678',
  accessToken: 'pca1.old',
  refreshToken: 'pcr1.old',
);

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'an expired access token is refreshed once and the calls repeated',
    () async {
      var refreshes = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/v1/customers/auth/refresh') {
          refreshes++;
          expect(jsonDecode(request.body)['refresh_token'], 'pcr1.old');
          return _json(200, {
            'access_token': 'pca1.new',
            'refresh_token': 'pcr1.new',
          });
        }
        if (request.headers['Authorization'] == 'Bearer pca1.new') {
          return _json(200, {
            'customer': {'id': 'c1'},
          });
        }
        return _json(401, {'code': 'token_expired'});
      });
      final sessions = MemorySessionStore(_session);
      final api = RelayApi(
        baseUrl: Uri.parse('https://relay.test'),
        sessions: sessions,
        client: client,
      );

      final answers = await Future.wait([
        api.get('/v1/customers/me', signedIn: true),
        api.get('/v1/customers/me', signedIn: true),
      ]);
      expect(
        answers.every((answer) => (answer['customer'] as Map)['id'] == 'c1'),
        isTrue,
      );
      expect(refreshes, 1);
      expect((await sessions.read())!.refreshToken, 'pcr1.new');
    },
  );

  test('a refused refresh signs the device out', () async {
    var signedOut = false;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/customers/auth/refresh') {
        return _json(401, {'code': 'invalid_refresh'});
      }
      return _json(401, {'code': 'token_expired'});
    });
    final sessions = MemorySessionStore(_session);
    final api = RelayApi(
      baseUrl: Uri.parse('https://relay.test'),
      sessions: sessions,
      client: client,
    )..onSignedOut = () => signedOut = true;

    await expectLater(
      api.get('/v1/customers/me', signedIn: true),
      throwsA(
        isA<RelayApiException>().having((e) => e.code, 'code', 'token_expired'),
      ),
    );
    expect(signedOut, isTrue);
    expect(await sessions.read(), isNull);
  });

  test(
    'a refusal carries the relay code and body; a dead network says so',
    () async {
      final api = RelayApi(
        baseUrl: Uri.parse('https://relay.test/base'),
        sessions: MemorySessionStore(),
        client: MockClient((request) async {
          expect(request.url.path, '/base/v1/customers/auth/verify');
          return _json(400, {
            'code': 'wrong_code',
            'error': 'the code is wrong',
            'attempts_left': 3,
          });
        }),
      );
      await expectLater(
        api.post('/v1/customers/auth/verify', body: {}),
        throwsA(
          isA<RelayApiException>()
              .having((e) => e.code, 'code', 'wrong_code')
              .having((e) => e.body['attempts_left'], 'attempts_left', 3),
        ),
      );

      final offline = RelayApi(
        baseUrl: Uri.parse('https://relay.test'),
        sessions: MemorySessionStore(),
        client: MockClient((_) => throw http.ClientException('no route')),
      );
      await expectLater(
        offline.get('/v1/customers/catalog'),
        throwsA(
          isA<RelayApiException>().having(
            (e) => e.isNetwork,
            'isNetwork',
            isTrue,
          ),
        ),
      );
    },
  );
}
