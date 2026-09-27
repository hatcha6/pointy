import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';

/// The purchasing catalog's "loading more" flag must come down on every path.
///
/// Field telemetry from a shop's back-office PC: the purchase screen drew a
/// frame on every vsync for hours — 671 frames per 10 s, overnight, with
/// nobody touching it — and 40–52% of frames were janky while a 107-line
/// order was being built. A search that replaced the catalog while page 2 was
/// still loading left the flag up forever: the footer spinner animated without
/// end, and the grid never loaded another page for the rest of the session.
void main() {
  ProductVariant variant(int id) =>
      ProductVariant(id: id, productId: id, sku: 'SKU$id', unitPrice: 1);

  test(
    'a search that replaces the catalog mid-page releases the page load',
    () async {
      final catalog = _GatedCatalogRepository();
      final viewModel = PurchaseViewModel(catalog, _FakePurchaseRepository());

      // The constructor loads the first page itself.
      catalog.respond(page: 1, variants: [variant(1)], hasMore: true);
      await pumpEventQueue();
      expect(viewModel.variants.map((v) => v.id), [1]);

      // The buyer scrolls to the end: page 2 is asked for and does not answer yet.
      final loadingMore = viewModel.loadMoreCatalog();
      expect(viewModel.isLoadingMore, isTrue);

      // ...and types a search before it does.
      final searching = viewModel.updateSearch('حليب');
      catalog.respond(page: 1, variants: [variant(7)], hasMore: true);
      catalog.respond(page: 2, variants: [variant(2)], hasMore: false);
      await Future.wait([loadingMore, searching]);

      expect(viewModel.isLoadingMore, isFalse);
      expect(viewModel.variants.map((v) => v.id), [7]);

      // And the new results still page.
      catalog.respond(page: 2, variants: [variant(8)], hasMore: false);
      await viewModel.loadMoreCatalog();
      expect(viewModel.variants.map((v) => v.id), [7, 8]);
      expect(viewModel.isLoadingMore, isFalse);
    },
  );

  test('a page load that throws does not leave the spinner up', () async {
    final catalog = _GatedCatalogRepository();
    final viewModel = PurchaseViewModel(catalog, _FakePurchaseRepository());
    // The constructor loads the first page itself.
    catalog.respond(page: 1, variants: [variant(1)], hasMore: true);
    await pumpEventQueue();
    expect(viewModel.variants.map((v) => v.id), [1]);

    // Not an Exception, so Result.guard lets it through — a parsing TypeError.
    catalog.fail(page: 2, error: StateError('bad page'));
    await expectLater(viewModel.loadMoreCatalog(), throwsStateError);

    expect(viewModel.isLoadingMore, isFalse);
  });
}

class _GatedCatalogRepository extends CatalogRepository {
  _GatedCatalogRepository() : super(PosApiService());

  final Map<int, List<Completer<Result<ProductVariantPage>>>> _pending = {};
  final Map<int, List<Object>> _queued = {};

  void respond({
    required int page,
    required List<ProductVariant> variants,
    required bool hasMore,
  }) {
    // Typed explicitly: passed as an Object, `Ok(...)` would infer Ok<Object>.
    _deliver(
      page,
      Ok<ProductVariantPage>(
        ProductVariantPage(variants: variants, hasMore: hasMore),
      ),
    );
  }

  void fail({required int page, required Object error}) {
    _deliver(page, error);
  }

  void _deliver(int page, Object outcome) {
    final waiting = _pending[page];
    if (waiting != null && waiting.isNotEmpty) {
      final completer = waiting.removeAt(0);
      if (outcome is Result<ProductVariantPage>) {
        completer.complete(outcome);
      } else {
        completer.completeError(outcome);
      }
      return;
    }
    (_queued[page] ??= []).add(outcome);
  }

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) {
    final queued = _queued[page];
    if (queued != null && queued.isNotEmpty) {
      final outcome = queued.removeAt(0);
      return outcome is Result<ProductVariantPage>
          ? Future.value(outcome)
          : Future.error(outcome);
    }
    final completer = Completer<Result<ProductVariantPage>>();
    (_pending[page] ??= []).add(completer);
    return completer.future;
  }
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());
}
