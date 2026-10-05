import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/tracked_stock_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/catalog_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/unit_search_lookup.dart';

import '../unit_search_fixtures.dart';

/// A fetch the test answers by hand, one completer per ask.
class _ScriptedFetch {
  final asked = <String>[];
  final _pending = <Completer<Result<StockUnitLookup>>>[];

  Future<Result<StockUnitLookup>> call(String code) {
    asked.add(code);
    final completer = Completer<Result<StockUnitLookup>>();
    _pending.add(completer);
    return completer.future;
  }

  void answer(int index, StockUnitLookup lookup) =>
      _pending[index].complete(Ok(lookup));

  void fail(int index) => _pending[index].complete(Error(Exception('offline')));
}

void main() {
  group('UnitSearchLookup', () {
    test('a name, a word or a short code asks nothing', () async {
      final fetch = _ScriptedFetch();
      final lookup = UnitSearchLookup(fetch.call);
      addTearDown(lookup.dispose);

      for (final text in ['حليب', 'iPhone 13', 'charger', '1234']) {
        lookup.search(text);
        expect(await lookup.resolve(text), isNull);
      }
      expect(fetch.asked, isEmpty);
      expect(lookup.isLoading, isFalse);
      expect(lookup.match, isNull);
    });

    test('an IMEI asks once, normalised, and holds the answer', () async {
      final fetch = _ScriptedFetch();
      final lookup = UnitSearchLookup(fetch.call);
      addTearDown(lookup.dispose);

      lookup.search('351234-567890116');
      expect(lookup.isLoading, isTrue);
      expect(fetch.asked, [imei]);

      // Enter before the answer: joins the ask already on its way.
      final resolved = lookup.resolve(imei);
      lookup.search(' $imei ');
      expect(fetch.asked, hasLength(1));

      fetch.answer(0, lookupOf(unit: liveUnitJson()));
      expect((await resolved)?.unit?.id, 41);
      expect(lookup.isLoading, isFalse);
      expect(lookup.match?.single?.id, 41);
      expect(lookup.code, imei);
    });

    test('a stale answer never overwrites the newer query', () async {
      final fetch = _ScriptedFetch();
      final lookup = UnitSearchLookup(fetch.call);
      addTearDown(lookup.dispose);

      lookup.search(imei);
      lookup.search(secondImei);
      fetch.answer(1, lookupOf(history: [soldUnitJson(id: 77)]));
      await Future<void>.delayed(Duration.zero);
      // The first query's answer arrives late, for a query nobody holds.
      fetch.answer(0, lookupOf(unit: liveUnitJson(id: 41)));
      await Future<void>.delayed(Duration.zero);

      expect(lookup.match?.single?.id, 77);
      expect(lookup.code, secondImei);
    });

    test(
      'typing on to a name clears the card and drops the late answer',
      () async {
        final fetch = _ScriptedFetch();
        final lookup = UnitSearchLookup(fetch.call);
        addTearDown(lookup.dispose);

        lookup.search(imei);
        lookup.search('آيفون');
        expect(lookup.isLoading, isFalse);
        fetch.answer(0, lookupOf(unit: liveUnitJson()));
        await Future<void>.delayed(Duration.zero);

        expect(lookup.match, isNull);
      },
    );

    test('nothing found and a failed ask are both silence', () async {
      final fetch = _ScriptedFetch();
      final lookup = UnitSearchLookup(fetch.call);
      addTearDown(lookup.dispose);

      final empty = lookup.resolve(imei);
      fetch.answer(0, lookupOf());
      expect(await empty, isNull);

      final failed = lookup.resolve(secondImei);
      fetch.fail(1);
      expect(await failed, isNull);
      expect(lookup.match, isNull);
      expect(lookup.isLoading, isFalse);
    });
  });

  group('StockUnitLookup.single — what Enter opens', () {
    test('one article answers', () {
      expect(lookupOf(unit: liveUnitJson()).single?.id, 41);
      expect(lookupOf(history: [soldUnitJson()]).single?.id, 40);
    });

    test('a trade-in is a choice, not a jump', () {
      expect(
        lookupOf(unit: liveUnitJson(), history: [soldUnitJson()]).single,
        isNull,
      );
      expect(
        lookupOf(history: [soldUnitJson(id: 2), soldUnitJson(id: 1)]).single,
        isNull,
      );
      expect(lookupOf().single, isNull);
    });
  });

  group('CatalogViewModel', () {
    late List<Uri> requested;
    late PosApiService service;

    setUp(() {
      requested = [];
      service = PosApiService(
        baseUrl: 'http://pointy.test/api',
        client: MockClient((request) async {
          requested.add(request.url);
          final body = request.url.path.endsWith('stock-units/lookup/')
              ? {'unit': liveUnitJson(), 'history': <Object?>[]}
              : {'results': <Object?>[], 'next': null};
          return http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
    });

    bool askedForUnits() =>
        requested.any((url) => url.path.endsWith('stock-units/lookup/'));

    test(
      'without the lookup an IMEI is a product search and nothing else',
      () async {
        final viewModel = CatalogViewModel(CatalogRepository(service));
        addTearDown(viewModel.dispose);

        await viewModel.updateSearch(imei);
        expect(await viewModel.resolveUnitMatch(imei), isNull);
        expect(askedForUnits(), isFalse);
        expect(viewModel.unitSearch, isNull);
      },
    );

    test('with it, the search asks beside the product list', () async {
      final viewModel = CatalogViewModel(
        CatalogRepository(service),
        unitSearch: UnitSearchLookup(
          TrackedStockRepository(service).lookupUnit,
        ),
      );
      addTearDown(viewModel.dispose);

      await viewModel.updateSearch(imei);
      final match = await viewModel.resolveUnitMatch(imei);
      expect(match?.single?.code, imei);
      expect(
        requested.where((url) => url.path.endsWith('stock-units/lookup/')),
        hasLength(1),
      );

      // A name typed next asks nothing more and clears the match.
      await viewModel.updateSearch('آيفون');
      expect(viewModel.unitSearch!.match, isNull);
      expect(
        requested.where((url) => url.path.endsWith('stock-units/lookup/')),
        hasLength(1),
      );
    });
  });
}
