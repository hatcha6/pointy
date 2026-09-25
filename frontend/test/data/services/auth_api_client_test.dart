import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/auth_api_client.dart';

const _lan = 'http://lan.test/api';
const _relay = 'https://relay.test/api';

http.Response _json(Map<String, Object?> body, int statusCode) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

const _userPayload = {
  'user': {'id': 1, 'username': 'owner', 'role': 'manager', 'is_active': true},
  'csrf_token': 'masked-token',
};

void main() {
  group('signing in', () {
    // The app reached the login screen because a probe failed, not because
    // the session ended: the session cookie is still live. DRF authenticates
    // the sign-in by that cookie first and then demands the CSRF token; a
    // sign-in without it was refused with 403 and shown as a wrong password.
    test('carries the CSRF token the session already holds', () async {
      final headersSeen = <Map<String, String>>[];
      final session = PosApiSession(
        client: MockClient((request) async {
          headersSeen.add(request.headers);
          if (request.url.path.endsWith('/auth/me/')) {
            return _json(_userPayload, 200);
          }
          return _json(_userPayload, 200);
        }),
        baseUrl: _lan,
      );
      // A response that set the cookies, as the backend does at sign-in.
      session.captureResponseState(
        http.Response(
          '',
          200,
          headers: {
            'set-cookie':
                'sessionid=live-session; Path=/, csrftoken=secret; Path=/',
          },
        ),
      );
      final client = AuthApiClient(session);

      await client.login(username: 'owner', password: 'pw');

      expect(headersSeen.single['X-CSRFToken'], 'secret');
      expect(headersSeen.single['Cookie'], contains('sessionid=live-session'));
    });

    test('a refused pair is reported with its status and body', () async {
      final session = PosApiSession(
        client: MockClient(
          (request) async => _json({
            'detail': ['Invalid username or password.'],
          }, 400),
        ),
        baseUrl: _lan,
      );
      final client = AuthApiClient(session);

      await expectLater(
        client.login(username: 'owner', password: 'pw'),
        throwsA(
          isA<PosApiException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.fromRelay, 'fromRelay', isFalse),
        ),
      );
    });
  });

  group('who am I, through the relay', () {
    test("the backend's 401 is a sign-out", () async {
      final session = PosApiSession(
        client: MockClient(
          (request) async => _json({
            'detail': 'Authentication credentials were not provided.',
          }, 401),
        ),
        baseUrl: _relay,
      )..configureConnectionTarget(baseUrl: _relay, relayToken: 'ptt1.ticket');

      expect(await AuthApiClient(session).fetchCurrentUser(), isNull);
    });

    // A ticket the relay refuses says nothing about the session behind it.
    // Reading it as "signed out" sent the phone to a login screen on which
    // no sign-in could ever succeed.
    test("the relay's 401 is not", () async {
      final session = PosApiSession(
        client: MockClient(
          (request) async => _json({'error': 'relay token rejected'}, 401),
        ),
        baseUrl: _relay,
      )..configureConnectionTarget(baseUrl: _relay, relayToken: 'ptt1.ticket');

      await expectLater(
        AuthApiClient(session).fetchCurrentUser(),
        throwsA(
          isA<PosApiException>()
              .having((e) => e.fromRelay, 'fromRelay', isTrue)
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });
  });
}
