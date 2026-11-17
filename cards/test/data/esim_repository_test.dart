import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/src/core/result.dart';
import 'package:pointy_cards/src/data/api/relay_api.dart';
import 'package:pointy_cards/src/data/models/esim.dart';
import 'package:pointy_cards/src/data/repositories/esim_repository.dart';
import 'package:pointy_cards/src/data/session/session_store.dart';
import 'package:pointy_cards/src/data/vault/esim_vault.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  var online = true;
  var owner = '';
  // What the relay's shelf and plans are tagged, and what each call asked.
  var version = 'v1';
  final asked = <String?>[];
  final sessions = MemorySessionStore();
  var vault = MemoryEsimVault();
  setUp(() async {
    online = true;
    owner = '';
    version = 'v1';
    asked.clear();
    vault = MemoryEsimVault();
    await sessions.clear();
  });

  Map<String, dynamic> esimRow({bool install = false}) => {
    'iccid': '8901',
    'order_id': 'order-1',
    'title': 'تركيا 1GB',
    'destination': 'turkey',
    'label': '',
    'usage': {'status': 'ACTIVE', 'remaining_mb': 512, 'total_mb': 1024},
    'created_at': '2026-11-01T10:00:00Z',
    if (install) 'install': {'qr': 'LPA:1\$smdp\$code', 'smdp': 'smdp'},
  };

  final client = MockClient((request) async {
    if (!online) {
      throw http.ClientException('offline');
    }
    final path = request.url.path;
    http.Response json(Object body, [Map<String, String>? headers]) =>
        http.Response(
          jsonEncode(body),
          200,
          headers: {
            'content-type': 'application/json; charset=utf-8',
            ...?headers,
          },
        );
    if (path == '/v1/customers/esims') {
      return json({
        'esims': [esimRow()],
      });
    }
    if (path == '/v1/customers/esims/8901') {
      return json({'esim': esimRow(install: true)});
    }
    final tag = '"$version${path.length}"';
    asked.add(request.headers['If-None-Match']);
    if (request.headers['If-None-Match'] == tag) {
      return http.Response('', 304, headers: {'etag': tag});
    }
    final body = path == '/v1/customers/esim/destinations'
        ? {
            'available': true,
            'destinations': [
              {
                'key': 'turkey',
                'kind': 'local',
                'country': 'TR',
                'name': 'تركيا',
                'from_price': '25.00',
                'plans': 1,
              },
            ],
          }
        : {
            'key': 'turkey',
            'kind': 'local',
            'country': 'TR',
            'name': 'تركيا',
            'plans': [
              {'id': 'tr-1gb', 'item': 'esim:tr-1gb', 'price': '25.00'},
            ],
          };
    return json(body, {'etag': tag});
  });

  // A new one each time: a launch.
  EsimRepository launch() => EsimRepository(
    api: RelayApi(
      baseUrl: Uri.parse('https://relay.test'),
      sessions: sessions,
      client: client,
    ),
    preferences: SharedPreferencesAsync(),
    vault: vault,
    owner: () => owner,
  );

  test('the shelf read online still shows on an offline launch', () async {
    final first = launch();
    expect(await first.cachedShelf(), isNull);
    expect(await first.loadShelf(), isA<Ok<Object?>>());

    online = false;
    final relaunched = launch();
    expect(relaunched.shelf.value.available, isFalse);
    final result = await relaunched.loadShelf();
    expect(result, isA<Error<Object?>>());
    // The home entry listens to this: it shows from the saved copy.
    expect(relaunched.shelf.value.available, isTrue);
    expect(relaunched.shelf.value.destinations.single.name, 'تركيا');
    expect((await relaunched.cachedShelf())!.destinations.single.key, 'turkey');
  });

  test('a destination opened once opens again offline', () async {
    final first = launch();
    expect(await first.cachedDestination('turkey'), isNull);
    expect(await first.destination('turkey'), isA<Ok<Object?>>());

    online = false;
    final relaunched = launch();
    final kept = await relaunched.cachedDestination('turkey');
    expect(kept!.plans.single.id, 'tr-1gb');
    expect(await relaunched.destination('turkey'), isA<Error<Object?>>());
    // One never opened has no saved copy.
    expect(await relaunched.cachedDestination('egypt'), isNull);
  });

  test('a saved copy is shown only to whoever it was read for', () async {
    owner = 'review-account';
    final first = launch();
    await first.loadShelf();
    await first.destination('turkey');

    online = false;
    owner = '';
    final signedOut = launch();
    expect(await signedOut.cachedShelf(), isNull);
    expect(await signedOut.cachedDestination('turkey'), isNull);
    await signedOut.loadShelf();
    expect(signedOut.shelf.value.available, isFalse);

    // The same repository, the customer gone: nothing read for them answers.
    expect(await first.cachedShelf(), isNull);
    expect(await first.cachedDestination('turkey'), isNull);
  });

  test('a saved copy that cannot be read is no saved copy', () async {
    await SharedPreferencesAsync().setString('cards.esim.shelf', '{"owner":');
    expect(await launch().cachedShelf(), isNull);
  });

  test('a shelf and plans that did not change cost a 304 each', () async {
    final first = launch();
    await first.loadShelf();
    await first.destination('turkey');
    expect(asked, [null, null]);

    final relaunched = launch();
    final shelf = await relaunched.loadShelf();
    expect((shelf as Ok<EsimShelf>).value.destinations.single.name, 'تركيا');
    final plans = await relaunched.destination('turkey');
    expect((plans as Ok<EsimDestination>).value.plans.single.id, 'tr-1gb');
    expect(asked.sublist(2), ['"v131"', '"v138"']);

    // The relay's copy moved: the tag no longer answers, and the new one is
    // kept for next time.
    version = 'v2';
    expect(await relaunched.loadShelf(), isA<Ok<Object?>>());
    expect(await launch().loadShelf(), isA<Ok<Object?>>());
    expect(asked.sublist(4), ['"v131"', '"v231"']);
  });

  test('a tag is never sent for a copy read for someone else', () async {
    owner = 'review-account';
    await launch().loadShelf();
    owner = '';
    await launch().loadShelf();
    expect(asked, [null, null]);
  });

  group('the customer\'s eSIMs', () {
    setUp(() async {
      owner = 'customer-1';
      await sessions.write(
        CustomerSession.fromJson({
          'session_id': 's',
          'access_token': 'a',
          'refresh_token': 'r',
          'customer': {'id': 'customer-1', 'phone': '0910000000'},
        }),
      );
    });

    test('are held on the phone, with how each installs', () async {
      final first = launch();
      expect(await first.keptEsims(), isEmpty);
      await first.esims();
      await first.esim('8901');
      // The list read again carries no install details: those read stay.
      await first.esims();

      online = false;
      final relaunched = launch();
      expect(await relaunched.esims(), isA<Error<Object?>>());
      expect((await relaunched.keptEsims()).single.title, 'تركيا 1GB');
      final byOrder = await relaunched.keptEsim(orderId: 'order-1');
      expect(byOrder!.iccid, '8901');
      final kept = await relaunched.keptEsim(iccid: '8901');
      expect(kept!.install!.smdp, 'smdp');
      expect(await relaunched.keptEsim(iccid: '0000'), isNull);
    });

    test('go with the customer', () async {
      final repository = launch();
      await repository.esims();

      // Someone else on this phone is shown none of them.
      owner = 'customer-2';
      repository.forget();
      expect(await repository.keptEsims(), isEmpty);
      expect(await launch().keptEsims(), isEmpty);

      // Signed out: the keychain forgets them.
      owner = 'customer-1';
      expect(await launch().keptEsims(), hasLength(1));
      await repository.clearKept();
      expect(await vault.read(), isNull);
      expect(await launch().keptEsims(), isEmpty);
    });
  });
}
