import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/src/core/result.dart';
import 'package:pointy_cards/src/data/api/relay_api.dart';
import 'package:pointy_cards/src/data/repositories/catalog_repository.dart';
import 'package:pointy_cards/src/data/session/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  CatalogRepository repository(http.Client client) => CatalogRepository(
    api: RelayApi(
      baseUrl: Uri.parse('https://relay.test'),
      sessions: MemorySessionStore(),
      client: client,
    ),
    channel: 'ios',
    preferences: SharedPreferencesAsync(),
  );

  test('the shelf is kept and an unchanged one costs a 304', () async {
    final seen = <String?>[];
    final client = MockClient((request) async {
      expect(request.url.queryParameters['channel'], 'ios');
      seen.add(request.headers['If-None-Match']);
      if (request.headers['If-None-Match'] == '"v1"') {
        return http.Response('', 304);
      }
      return http.Response(
        jsonEncode({
          'version': 'v1',
          'brands': [
            {'key': 'libyana', 'name': 'ليبيانا', 'items': []},
          ],
        }),
        200,
        headers: {
          'etag': '"v1"',
          'content-type': 'application/json; charset=utf-8',
        },
      );
    });
    final first = await repository(client).refresh();
    expect((first as Ok).value.brands.single.name, 'ليبيانا');

    // A new launch: the shelf comes from the device at once, then a 304.
    final relaunched = repository(client);
    expect((await relaunched.cached())!.version, 'v1');
    final second = await relaunched.refresh();
    expect((second as Ok).value.version, 'v1');
    expect(seen, [null, '"v1"']);
  });

  test('image references resolve to the public image route', () {
    final repo = repository(MockClient((_) async => http.Response('', 404)));
    expect(
      repo.imageUrl('sha256:abc').toString(),
      'https://relay.test/v1/customers/images/abc',
    );
  });
}
