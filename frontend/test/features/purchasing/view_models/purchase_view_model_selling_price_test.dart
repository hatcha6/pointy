import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';

/// The cart line's selling price is only useful if it is the price the shop is
/// actually charging today — these cover every way a line's price can go stale.
void main() {
  const coffee = ProductVariant(
    id: 11,
    productId: 5,
    sku: 'COF',
    unitPrice: 10,
  );
  const tea = ProductVariant(id: 12, productId: 6, sku: 'TEA', unitPrice: 4);

  String persistedDraft(List<ProductVariant> variants) {
    return jsonEncode({
      'version': 1,
      'lines': [
        for (final variant in variants)
          PurchaseDraftLine(
            variant: variant,
            quantity: 1,
            unitCost: 2,
          ).toJson(),
      ],
    });
  }

  double priceOf(PurchaseViewModel viewModel, int variantId) {
    return viewModel.draft
        .firstWhere((line) => line.variant.id == variantId)
        .variant
        .unitPrice;
  }

  test(
    'repricing a product updates the price shown on its draft lines',
    () async {
      final catalog = _FakeCatalogRepository();
      final viewModel = PurchaseViewModel(catalog, _FakePurchaseRepository());
      await viewModel.addVariant(coffee);

      var notifications = 0;
      viewModel.addListener(() => notifications += 1);
      final ok = await viewModel.repriceProduct(5, pricesByVariant: {11: 14});

      expect(ok, isTrue);
      expect(priceOf(viewModel, 11), 14);
      expect(notifications, 1, reason: 'the cart line has to repaint');
    },
  );

  test('a failed reprice leaves the shown price alone', () async {
    final catalog = _FakeCatalogRepository(repriceFails: true);
    final viewModel = PurchaseViewModel(catalog, _FakePurchaseRepository());
    await viewModel.addVariant(coffee);

    final ok = await viewModel.repriceProduct(5, pricesByVariant: {11: 14});

    expect(ok, isFalse);
    expect(priceOf(viewModel, 11), 10);
  });

  test('a catalog page heals a stale cart line for free', () async {
    final catalog = _FakeCatalogRepository();
    final viewModel = PurchaseViewModel(catalog, _FakePurchaseRepository());
    await viewModel.addVariant(coffee);

    // The shop repriced this product elsewhere; the next catalog page the pane
    // loads anyway carries the new price.
    catalog.catalogVariants = const [
      ProductVariant(id: 11, productId: 5, sku: 'COF', unitPrice: 12),
    ];
    await viewModel.loadCatalog();

    expect(priceOf(viewModel, 11), 12);
  });

  test('an unchanged catalog price does not repaint the cart', () async {
    final catalog = _FakeCatalogRepository();
    final viewModel = PurchaseViewModel(catalog, _FakePurchaseRepository());
    await viewModel.addVariant(coffee);
    catalog.catalogVariants = const [coffee];

    var notifications = 0;
    viewModel.addListener(() => notifications += 1);
    await viewModel.loadCatalog();

    // Two, and only two: the load starting and the load finishing.
    expect(notifications, 2);
  });

  test('a restored draft refreshes every line in one request', () async {
    final catalog = _FakeCatalogRepository()
      ..variantsById = const [
        ProductVariant(id: 11, productId: 5, sku: 'COF', unitPrice: 13),
        ProductVariant(id: 12, productId: 6, sku: 'TEA', unitPrice: 4),
      ];
    final storage = MemoryScopedJsonStorage();
    await storage.save('user-1', persistedDraft([coffee, tea]));
    final viewModel = PurchaseViewModel(
      catalog,
      _FakePurchaseRepository(),
      draftStorage: storage,
    );

    await viewModel.restorePersistedDraft('user-1');
    await pumpEventQueue();

    expect(
      catalog.requestedVariantIdBatches,
      [
        {11, 12},
      ],
      reason: 'one batched request for the whole cart, not one per line',
    );
    expect(priceOf(viewModel, 11), 13);
    expect(priceOf(viewModel, 12), 4);
  });

  test('an unresolvable line keeps its last known price', () async {
    // The product was archived since the draft was saved, so the refresh comes
    // back without it — better a stale price than no price at all.
    final catalog = _FakeCatalogRepository()..variantsById = const [];
    final storage = MemoryScopedJsonStorage();
    await storage.save('user-1', persistedDraft([coffee]));
    final viewModel = PurchaseViewModel(
      catalog,
      _FakePurchaseRepository(),
      draftStorage: storage,
    );

    await viewModel.restorePersistedDraft('user-1');
    await pumpEventQueue();

    expect(priceOf(viewModel, 11), 10);
  });

  test('an empty draft never asks for prices', () async {
    final catalog = _FakeCatalogRepository();
    final viewModel = PurchaseViewModel(catalog, _FakePurchaseRepository());

    await viewModel.refreshDraftSellingPrices();

    expect(catalog.requestedVariantIdBatches, isEmpty);
  });

  test('a second refresh cannot pile onto one already in flight', () async {
    final catalog = _FakeCatalogRepository()
      ..variantsById = const [coffee]
      ..holdVariantIdRequests = true;
    final viewModel = PurchaseViewModel(catalog, _FakePurchaseRepository());
    await viewModel.addVariant(coffee);

    final first = viewModel.refreshDraftSellingPrices();
    await viewModel.refreshDraftSellingPrices();
    catalog.releaseVariantIdRequests();
    await first;

    expect(catalog.requestedVariantIdBatches.length, 1);
  });
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository({this.repriceFails = false}) : super(PosApiService());

  final bool repriceFails;
  List<ProductVariant> catalogVariants = const [];
  List<ProductVariant> variantsById = const [];
  final List<Set<int>> requestedVariantIdBatches = [];
  bool holdVariantIdRequests = false;
  final List<void Function()> _held = [];

  void releaseVariantIdRequests() {
    for (final release in _held) {
      release();
    }
    _held.clear();
  }

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => Ok(ProductVariantPage(variants: catalogVariants, hasMore: false));

  @override
  Future<List<ProductVariant>> loadVariantsByIds(Iterable<int> ids) async {
    requestedVariantIdBatches.add({...ids});
    if (holdVariantIdRequests) {
      final gate = Completer<void>();
      _held.add(gate.complete);
      await gate.future;
    }
    final requested = {...ids};
    return [
      for (final variant in variantsById)
        if (requested.contains(variant.id)) variant,
    ];
  }

  @override
  Future<Result<Product>> setVariantPrices({
    required int productId,
    required Map<int, double> pricesByVariant,
    Map<String, double?> pricesByUnitCode = const {},
  }) async {
    if (repriceFails) {
      return Error(Exception('reprice failed'));
    }
    return Ok(Product(id: productId, name: 'p', quantityOnHand: 0));
  }
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());

  @override
  Future<Result<double?>> loadLastProductCost(
    int productId, {
    int? variantId,
  }) async => const Ok(null);
}
