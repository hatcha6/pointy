import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bought_together_product.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/product_details_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/change_prices_dialog.dart';

void main() {
  Product buildProduct() => const Product(
    id: 1,
    name: 'Shirt',
    quantityOnHand: 0,
    variants: [
      ProductVariant(id: 11, productId: 1, sku: 'SH-S', unitPrice: 10),
      ProductVariant(id: 12, productId: 1, sku: 'SH-L', unitPrice: 12),
    ],
  );

  List<VariantCostSummary> buildSummaries() => const [
    VariantCostSummary(
      productId: 1,
      variantId: 11,
      variantName: 'Small',
      unitPrice: 10,
      purchasesCount: 2,
      lowestCost: 4,
      highestCost: 6,
      lastCost: 5,
      averageCost: 5,
    ),
    VariantCostSummary(
      productId: 1,
      variantId: 12,
      variantName: 'Large',
      unitPrice: 12,
      purchasesCount: 1,
      lowestCost: 7,
      highestCost: 7,
      lastCost: 7,
      averageCost: 7,
    ),
  ];

  Future<_Harness> pumpDialog(WidgetTester tester) async {
    final catalog = _FakeCatalogRepository(buildProduct());
    final purchase = _FakePurchaseRepository(buildSummaries());
    final viewModel = ProductDetailsViewModel(
      catalog,
      purchase,
      _FakeSaleRepository(),
      buildProduct(),
      shouldLoadSaleHistory: false,
      shouldLoadPurchaseHistory: true,
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showChangePricesDialog(context, viewModel),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return _Harness(catalog: catalog, viewModel: viewModel);
  }

  testWidgets('renders a row per variant with its costs', (tester) async {
    await pumpDialog(tester);

    expect(find.text('Small'), findsOneWidget);
    expect(find.text('Large'), findsOneWidget);
    // Two editable new-price fields, one per variant.
    expect(find.byType(TextFormField), findsNWidgets(2));
  });

  testWidgets('writes only changed prices through the view model', (
    tester,
  ) async {
    final harness = await pumpDialog(tester);

    // Change the first variant's price; leave the second untouched.
    await tester.enterText(find.byType(TextFormField).first, '15.00');
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await tester.tap(find.text(l10n.changePricesSaveButton));
    await tester.pumpAndSettle();

    expect(harness.catalog.lastPrices, {11: 15.0});
  });
}

class _Harness {
  _Harness({required this.catalog, required this.viewModel});

  final _FakeCatalogRepository catalog;
  final ProductDetailsViewModel viewModel;
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository(this._product) : super(PosApiService());

  final Product _product;
  Map<int, double>? lastPrices;

  @override
  Future<Result<Product>> loadProduct(int id) async => Ok(_product);

  @override
  Future<Result<List<BoughtTogetherProduct>>> loadBoughtTogether(
    int productId, {
    int limit = 8,
  }) async => const Ok([]);

  @override
  Future<Result<Product>> setVariantPrices({
    required int productId,
    required Map<int, double> pricesByVariant,
  }) async {
    lastPrices = pricesByVariant;
    return Ok(_product);
  }
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository(this._summaries) : super(PosApiService());

  final List<VariantCostSummary> _summaries;

  @override
  Future<Result<List<VariantCostSummary>>> loadProductCostSummary(
    int productId,
  ) async => Ok(_summaries);

  @override
  Future<Result<PurchaseOrderPage>> loadPurchaseOrders({
    required PurchaseOrderQuery query,
    int page = 1,
  }) async => const Ok(PurchaseOrderPage(orders: [], hasMore: false));
}

class _FakeSaleRepository extends SaleRepository {
  _FakeSaleRepository() : super(PosApiService());
}
