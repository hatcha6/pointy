import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';

void main() {
  const siblings = [
    ProductVariant(id: 1, productId: 5, sku: 'A', unitPrice: 2),
    ProductVariant(id: 2, productId: 5, sku: 'B', unitPrice: 3),
  ];

  test('loadSiblingVariants returns the product\'s variants', () async {
    final catalog = _FakeCatalogRepository(siblings: siblings);
    final viewModel = PurchaseViewModel(catalog, _FakePurchaseRepository());

    final result = await viewModel.loadSiblingVariants(5);

    expect(result.map((v) => v.id), [1, 2]);
    expect(catalog.loadedProductId, 5);
  });

  test(
    'loadPricingSuggestion returns the suggested price and markup',
    () async {
      final viewModel = PurchaseViewModel(
        _FakeCatalogRepository(),
        _FakePurchaseRepository(suggestedPrice: 13, markupPercent: 30),
      );

      final suggestion = await viewModel.loadPricingSuggestion(10);

      expect(suggestion.suggestedPrice, 13);
      expect(suggestion.markupPercent, 30);
    },
  );

  test('repriceProduct forwards the changed variant prices', () async {
    final catalog = _FakeCatalogRepository(siblings: siblings);
    final viewModel = PurchaseViewModel(catalog, _FakePurchaseRepository());

    final ok = await viewModel.repriceProduct(
      5,
      pricesByVariant: {1: 2.5, 2: 3.5},
    );

    expect(ok, isTrue);
    expect(catalog.repricedProductId, 5);
    expect(catalog.repricedPrices, {1: 2.5, 2: 3.5});
  });

  test('repriceProduct forwards pack prices alongside variant ones', () async {
    final catalog = _FakeCatalogRepository(siblings: siblings);
    final viewModel = PurchaseViewModel(catalog, _FakePurchaseRepository());

    final ok = await viewModel.repriceProduct(
      5,
      pricesByVariant: {1: 2.5},
      pricesByUnitCode: {'carton': 26.0},
    );

    expect(ok, isTrue);
    expect(catalog.repricedPrices, {1: 2.5});
    expect(catalog.repricedUnitPrices, {'carton': 26.0});
  });

  test('a pack handed back to derived sends an explicit null', () async {
    final catalog = _FakeCatalogRepository(siblings: siblings);
    final viewModel = PurchaseViewModel(catalog, _FakePurchaseRepository());

    final ok = await viewModel.repriceProduct(
      5,
      pricesByUnitCode: {'carton': null},
    );

    expect(ok, isTrue);
    expect(catalog.repricedUnitPrices, containsPair('carton', isNull));
  });

  test('repriceProduct with no changes is a no-op success', () async {
    final catalog = _FakeCatalogRepository(siblings: siblings);
    final viewModel = PurchaseViewModel(catalog, _FakePurchaseRepository());

    final ok = await viewModel.repriceProduct(5);

    expect(ok, isTrue);
    expect(
      catalog.repricedPrices,
      isNull,
      reason: 'setVariantPrices not called',
    );
  });
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository({this.siblings = const []}) : super(PosApiService());

  final List<ProductVariant> siblings;
  int? loadedProductId;
  int? repricedProductId;
  Map<int, double>? repricedPrices;
  Map<String, double?>? repricedUnitPrices;

  // The view model's constructor kicks off loadCatalog(); keep it inert.
  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => const Ok(ProductVariantPage(variants: [], hasMore: false));

  @override
  Future<Result<Product>> loadProduct(int id) async =>
      Error(Exception('product $id not found'));

  @override
  Future<Result<ProductVariantPage>> loadVariantsForProduct(
    int productId, {
    int page = 1,
  }) async {
    loadedProductId = productId;
    return Ok(ProductVariantPage(variants: siblings, hasMore: false));
  }

  @override
  Future<Result<Product>> setVariantPrices({
    required int productId,
    required Map<int, double> pricesByVariant,
    Map<String, double?> pricesByUnitCode = const {},
  }) async {
    repricedProductId = productId;
    repricedPrices = pricesByVariant;
    repricedUnitPrices = pricesByUnitCode;
    return Ok(Product(id: productId, name: 'p', quantityOnHand: 0));
  }
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository({this.suggestedPrice, this.markupPercent})
    : super(PosApiService());

  final double? suggestedPrice;
  final double? markupPercent;

  @override
  Future<Result<({double? suggestedPrice, double? markupPercent})>>
  loadPricingSuggestion(double unitCost, {int? productId}) async {
    return Ok((suggestedPrice: suggestedPrice, markupPercent: markupPercent));
  }
}
