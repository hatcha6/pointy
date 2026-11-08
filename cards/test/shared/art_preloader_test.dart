import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/src/data/api/relay_api.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/data/repositories/catalog_repository.dart';
import 'package:pointy_cards/src/data/session/session_store.dart';
import 'package:pointy_cards/src/shared/art_preloader.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

CardBrand _brand(
  String key,
  String category, {
  bool featured = false,
  String? logo,
  int? rank,
}) => CardBrand.fromJson({
  'key': key,
  'name': key,
  'category': category,
  'featured': featured,
  'logo': logo ?? 'sha256:$key',
  'rank': rank ?? 0,
  'items': const <Object>[],
});

CardCatalog _shelf(List<CardBrand> brands) => CardCatalog(
  version: '1',
  channel: 'ios',
  testMode: false,
  brands: brands,
  categories: const [],
  countries: const [],
);

ImageProvider _picture(String url, {int? width}) =>
    MemoryImage(Uint8List.fromList(url.codeUnits));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final catalog = CatalogRepository(
    api: RelayApi(
      baseUrl: Uri.parse('https://relay.test'),
      sessions: MemorySessionStore(),
      client: MockClient((_) async => http.Response('', 404)),
    ),
    channel: 'ios',
  );

  test('the head of every row comes before the end of any', () {
    final order = ArtPreloader.preloadOrder([
      _brand('a1', 'a', rank: 1),
      _brand('a2', 'a', rank: 2),
      _brand('a3', 'a', rank: 3),
      _brand('b1', 'b', rank: 4),
      _brand('f', 'b', featured: true, rank: 5),
      _brand('none', 'c', logo: '', rank: 6),
    ]);
    expect(order.map((b) => b.key), ['f', 'a1', 'b1', 'a2', 'a3']);
  });

  test('only stored art is decoded, none is downloaded', () async {
    final decoded = <ImageProvider>[];
    final asked = <String>[];
    final preloader = ArtPreloader(
      catalog: catalog,
      isStored: (url) async {
        asked.add(url);
        return url.contains('stored');
      },
      decode: (image) async => decoded.add(image),
      memoryUsed: () => 0,
      picture: _picture,
    );

    await preloader.preload(
      _shelf([_brand('stored', 'a', rank: 1), _brand('new', 'a', rank: 2)]),
    );

    expect(asked, hasLength(2));
    expect(decoded, hasLength(1));
  });

  test('it stops at its memory budget and on memory pressure', () async {
    var decoded = 0;
    final full = ArtPreloader(
      catalog: catalog,
      isStored: (_) async => true,
      decode: (_) async => decoded++,
      memoryUsed: () => kArtMemoryBytes,
    );
    await full.preload(_shelf([_brand('a', 'a', rank: 1)]));
    expect(decoded, 0);

    final pressed = ArtPreloader(
      catalog: catalog,
      isStored: (_) async => true,
      decode: (_) async => decoded++,
      memoryUsed: () => 0,
    )..didHaveMemoryPressure();
    await pressed.preload(_shelf([_brand('a', 'a', rank: 1)]));
    expect(decoded, 0);
  });

  test('the first screen never holds the app up for long', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final saved = CatalogRepository(
      api: catalog.api,
      channel: 'ios',
      preferences: SharedPreferencesAsync(),
    );
    await SharedPreferencesAsync().setString(
      'cards.catalog.ios.body',
      jsonEncode({
        'brands': [
          for (var i = 0; i < 60; i++)
            {
              'key': 'b$i',
              'name': 'b$i',
              'category': 'c$i',
              'logo': 'sha256:$i',
            },
        ],
      }),
    );
    var asked = 0;
    final never = ArtPreloader(
      catalog: saved,
      isStored: (_) async {
        asked++;
        return true;
      },
      decode: (_) => Completer<void>().future,
      memoryUsed: () => 0,
      picture: _picture,
    );

    await never.prepareFirstScreen();

    expect(asked, 4);
  });

  test('a device with no saved shelf opens at once', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    var asked = 0;
    await ArtPreloader(
      catalog: CatalogRepository(
        api: catalog.api,
        channel: 'ios',
        preferences: SharedPreferencesAsync(),
      ),
      isStored: (_) async {
        asked++;
        return true;
      },
    ).prepareFirstScreen();
    expect(asked, 0);
  });
}
