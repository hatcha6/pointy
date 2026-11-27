import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/features/shelf/shelf_model.dart';

void main() {
  http.Response json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  final brands = fixtureCatalog['brands'] as List;

  test('a first launch shows the first part, then the whole shelf', () async {
    final whole = Completer<void>();
    final client = MockClient((request) async {
      if (request.url.path != '/v1/customers/catalog') {
        return json(const {});
      }
      if (request.url.queryParameters['part'] == 'first') {
        return json({
          ...fixtureCatalog,
          'version': 'v-first',
          'partial': true,
          'brands': brands.take(1).toList(),
        });
      }
      // The whole shelf is slow to arrive.
      await whole.future;
      return json(fixtureCatalog);
    });
    final dependencies = fixtureDependencies(client: client, signedIn: false);
    final shelf = ShelfModel(
      catalog: dependencies.catalog,
      orders: dependencies.orders,
      auth: dependencies.auth,
    );
    final loaded = shelf.load();

    await pumpEventQueue();
    expect(shelf.loading, isFalse);
    expect(shelf.partial, isTrue);
    expect(shelf.shelf.brands, hasLength(1));

    whole.complete();
    await loaded;
    expect(shelf.partial, isFalse);
    expect(shelf.shelf.brands, hasLength(brands.length));

    // The first part was never saved as the device's copy.
    expect((await dependencies.catalog.cached())!.partial, isFalse);
  });

  test('a first part that arrives after the whole shelf is ignored', () async {
    final first = Completer<void>();
    final client = MockClient((request) async {
      if (request.url.queryParameters['part'] == 'first') {
        await first.future;
        return json({...fixtureCatalog, 'partial': true, 'brands': []});
      }
      return json(fixtureCatalog);
    });
    final dependencies = fixtureDependencies(client: client, signedIn: false);
    final shelf = ShelfModel(
      catalog: dependencies.catalog,
      orders: dependencies.orders,
      auth: dependencies.auth,
    );
    await shelf.load();
    first.complete();
    await pumpEventQueue();
    expect(shelf.partial, isFalse);
    expect(shelf.shelf.brands, hasLength(brands.length));
  });
}
