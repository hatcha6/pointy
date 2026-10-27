import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:pointy_cards/src/core/analytics/analytics.dart';
import 'package:pointy_cards/src/core/push/follow_push_token.dart';
import 'package:pointy_cards/src/core/push/push.dart';

/// Notifications on a phone whose token can change.
class TokenPush extends FixturePush {
  String token = 'tok-1';
  final changes = StreamController<String>.broadcast();

  @override
  Future<String?> deviceToken() async => enabled ? token : null;

  @override
  Stream<String> get tokenChanges => changes.stream;
}

void main() {
  test('the relay is told where this phone takes notifications', () async {
    final told = <String>[];
    final relay = fixtureRelay();
    final client = MockClient((request) async {
      if (request.method == 'PUT' &&
          request.url.path == '/v1/customers/me/push') {
        told.add((jsonDecode(request.body) as Map)['token'] as String);
        return http.Response('', 204);
      }
      return relay.send(request).then(http.Response.fromStream);
    });
    final push = TokenPush();
    final dependencies = fixtureDependencies(client: client, push: push);
    followPushToken(dependencies);
    await pumpEventQueue();
    // Signed in, notifications still off: nothing to give.
    expect(told, ['']);

    await push.setEnabled(true);
    await pumpEventQueue();
    expect(told, ['', 'tok-1']);

    // Firebase replaced the token.
    push.token = 'tok-2';
    push.changes.add('tok-2');
    await pumpEventQueue();
    expect(told.last, 'tok-2');

    await push.setEnabled(false);
    await pumpEventQueue();
    expect(told.last, '');

    // Signed out: the session (and its token) is gone at the relay.
    final count = told.length;
    dependencies.auth.session.value = null;
    await push.setEnabled(true);
    await pumpEventQueue();
    expect(told, hasLength(count));
  });

  test('listening for new tokens before Firebase starts does not throw', () {
    // At launch the app listens before Firebase has started: touching
    // FirebaseMessaging.instance then throws, and the app never left its
    // splash.
    final push = FirebasePush(
      options: const FirebaseOptions(
        apiKey: 'k',
        appId: '1:1:ios:1',
        messagingSenderId: '1',
        projectId: 'p',
      ),
      channel: 'ios',
      analytics: NoAnalytics(),
    );
    expect(() => push.tokenChanges.listen((_) {}), returnsNormally);
  });
}
