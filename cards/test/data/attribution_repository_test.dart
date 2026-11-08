import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/core/money.dart';
import 'package:pointy_cards/src/core/result.dart';
import 'package:pointy_cards/src/data/api/relay_api.dart';
import 'package:pointy_cards/src/core/analytics/analytics.dart';
import 'package:pointy_cards/src/data/repositories/attribution_repository.dart';
import 'package:pointy_cards/src/data/repositories/auth_repository.dart';
import 'package:pointy_cards/src/data/session/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// A relay that records what it was sent and answers like the real one.
class _Relay {
  final requests = <(String, String, Map<String, dynamic>)>[];
  bool offline = false;

  http.Client get client => MockClient((request) async {
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    requests.add((request.method, request.url.path, body));
    if (offline) {
      throw http.ClientException('offline');
    }
    http.Response json(Object answer, [int status = 200]) => http.Response(
      jsonEncode(answer),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
    final attribution = body['attribution'] as Map<String, dynamic>?;
    return switch ((request.method, request.url.path)) {
      ('POST', '/v1/customers/auth/verify') => json({
        'access_token': 'pca1.a',
        'refresh_token': 'pcr1.r',
        'access_expires_at': '2030-01-01T00:00:00Z',
        'expires_at': '2030-01-01T00:00:00Z',
        'session': {'id': 'session-1'},
        'customer': {'id': 'customer-1', 'phone': '218912345678'},
        'created': true,
        if (attribution != null)
          'attribution': {'campaign_code': attribution['code'] ?? ''},
        if (attribution?['code'] == 'UNI1') 'code_accepted': true,
        if (attribution?['code'] == 'UNI1') 'reward': fixtureReward(),
      }),
      ('GET', '/v1/customers/campaigns/UNI1') ||
      (
        'POST',
        '/v1/customers/campaigns/UNI1/open',
      ) => json({'campaign': fixtureCampaign}),
      ('GET', _) => json({'code': 'unknown_campaign'}, 404),
      ('PUT', '/v1/customers/me/attribution') => json({
        'attribution': {'heard_from': body['heard_from'] ?? ''},
        'code_accepted': body['code'] == 'UNI1',
        if (body['code'] == 'UNI1') 'reward': fixtureReward(via: 'code'),
      }),
      _ => json({'code': 'not_found'}, 404),
    };
  });
}

void main() {
  late _Relay relay;
  late MemorySessionStore sessions;
  late AuthRepository auth;
  late AttributionRepository attribution;

  AttributionRepository build({Future<InstallReferrer> Function()? referrer}) {
    final api = RelayApi(
      baseUrl: Uri.parse('https://relay.test'),
      sessions: sessions,
      client: relay.client,
    );
    late final AuthRepository signIn;
    final repository = AttributionRepository(
      api: api,
      isSignedIn: () => signIn.isSignedIn,
      preferences: SharedPreferencesAsync(),
      installReferrer: referrer,
    );
    signIn = AuthRepository(
      api: api,
      sessions: sessions,
      attribution: repository,
    );
    auth = signIn;
    return repository;
  }

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    relay = _Relay();
    sessions = MemorySessionStore();
    attribution = build();
  });

  test('a followed link\'s code waits through a closed app and rides on the sign-in', () async {
    await attribution.load();
    attribution.openedLink(Uri.parse('https://cards.dftr.ly/go/uni1'));
    await pumpEventQueue();
    expect(attribution.pending.code, 'UNI1');
    expect(attribution.pending.via, 'link');
    expect(attribution.offer?.reward, Money.parse('5'));
    // Signed out: counted as an open, nothing sent to a customer yet.
    expect(relay.requests.map((r) => r.$2), [
      '/v1/customers/campaigns/UNI1/open',
    ]);

    // The app is closed and opened again: the code is still there.
    final reopened = build();
    await reopened.load();
    expect(reopened.pending.code, 'UNI1');

    final signedIn = await auth.verify('0912345678', '123456');
    expect(signedIn, isA<Ok<Object>>());
    final verify = relay.requests.last;
    expect(verify.$2, '/v1/customers/auth/verify');
    expect(verify.$3['attribution'], {'code': 'UNI1', 'via': 'link'});
    // Taken: nothing waits, and the reward waits to be shown.
    expect(reopened.pending.isEmpty, isTrue);
    expect(reopened.reward.value?.amount, Money.parse('5'));
    expect(reopened.reward.value?.kind, 'flyer');
    expect(reopened.shouldAskAfterSignIn, isTrue);
    reopened.rewardShown();
    expect(reopened.reward.value, isNull);
  });

  test(
    'a code checked before sign-in, then the answer, survive a failed send',
    () async {
      await attribution.load();
      final checked = await attribution.check('uni1');
      final offer = (checked as Ok).value;
      expect(await attribution.check('NOPE'), isA<Error<Object>>());

      await attribution.answer(heardFrom: 'friend', code: offer);
      expect(attribution.asked, isTrue);
      expect(attribution.forSignIn, {
        'code': 'UNI1',
        'via': 'code',
        'heard_from': 'friend',
      });

      // Signed in by some older path the relay did not attach it to: it is
      // sent on its own, and while offline it keeps waiting.
      await sessions.write(fixtureSession);
      auth.session.value = fixtureSession;
      relay.offline = true;
      await attribution.flush();
      expect(attribution.pending.code, 'UNI1');

      relay.offline = false;
      await attribution.flush();
      final put = relay.requests.last;
      expect((put.$1, put.$2), ('PUT', '/v1/customers/me/attribution'));
      expect(put.$3, {'code': 'UNI1', 'via': 'code', 'heard_from': 'friend'});
      expect(attribution.pending.isEmpty, isTrue);
      expect(attribution.reward.value?.via, 'code');
    },
  );

  test('the web\'s ?c= and Google Play\'s referrer are codes too; the first one stays', () async {
    // Play busy on the first launch: asked again on the next.
    attribution = build(referrer: () async => const InstallReferrer.later());
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await attribution.load();
    await pumpEventQueue();
    expect(attribution.pending.code, isEmpty);

    attribution = build(
      referrer: () async => const InstallReferrer(
        'utm_source=cards_link&utm_medium=flyer&utm_campaign=UNI1',
      ),
    );
    await attribution.load();
    await pumpEventQueue();
    expect(attribution.pending.code, 'UNI1');
    expect(attribution.pending.via, 'referrer');

    attribution.openedLink(
      Uri.parse('https://cards.dftr.ly/brand/pubg?c=AHMED'),
    );
    expect(attribution.pending.code, 'UNI1');

    // Read once per install.
    final again = build(referrer: () async => throw StateError('read twice'));
    await again.load();
    await pumpEventQueue();
    expect(again.pending.code, 'UNI1');
  });

  test('rewards wait while the sign-in sheet holds them', () async {
    var told = 0;
    attribution.reward.addListener(
      () => told += attribution.reward.value == null ? 0 : 1,
    );
    attribution.hold();
    await sessions.write(fixtureSession);
    auth.session.value = fixtureSession;
    await attribution.answer(
      code: (await attribution.check('UNI1') as Ok).value,
    );
    expect(attribution.holding, isTrue);
    expect(told, 1);
    attribution.release();
    expect(attribution.holding, isFalse);
    expect(told, 2, reason: 'told again once it can show');
  });

  test(
    'the answer outlives the relay taking it, and reaches a later launch',
    () async {
      await attribution.load();
      await attribution.answer(heardFrom: 'friend');
      expect(attribution.pending.heardFrom, 'friend');
      expect(attribution.heardFrom, 'friend');

      final later = build();
      await later.load();
      expect(later.heardFrom, 'friend');

      // The first answer stands.
      await later.answer(heardFrom: 'shop');
      expect(later.heardFrom, 'friend');
    },
  );

  test('a skip gives no answer to remember', () async {
    await attribution.load();
    attribution.skip();
    expect(attribution.heardFrom, '');
  });

  test('answered signed in, analytics is told at once', () async {
    final told = <Map<String, Object>>[];
    final repository = AttributionRepository(
      api: RelayApi(
        baseUrl: Uri.parse('https://relay.test'),
        sessions: sessions,
        client: relay.client,
      ),
      isSignedIn: () => true,
      analytics: _Person(told),
    );
    await repository.answer(heardFrom: 'facebook');
    expect(told, [
      {'heard_from': 'facebook'},
    ]);
  });
}

class _Person extends NoAnalytics {
  _Person(this.told);

  final List<Map<String, Object>> told;

  @override
  void setPersonOnce(Map<String, Object> properties) => told.add(properties);
}
