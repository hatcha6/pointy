import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_unit.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_pricing_sheet.dart';

void main() {
  // A product bought by the carton of 12 at 24 per carton — i.e. 2 per base
  // unit. Selling prices are stored per base unit, so every figure in the sheet
  // has to be based on 2, never on 24.
  const carton = ProductUnit(
    unit: UnitOfMeasure(id: 1, code: 'carton', name: 'كرتونة'),
    factorToBase: 12,
    price: 26,
  );
  final product = Product(
    id: 5,
    name: 'قهوة',
    quantityOnHand: 0,
    units: const [carton],
  );
  final variant = ProductVariant(
    id: 11,
    productId: 5,
    sku: 'A',
    unitPrice: 10,
    productDetail: product,
  );
  final cartonLine = PurchaseDraftLine(
    variant: variant,
    quantity: 1,
    unitCost: 24,
    unitCode: 'carton',
    unitLabel: 'كرتونة',
    unitFactor: 12,
  );

  Future<_Harness> pumpSheet(
    WidgetTester tester, {
    double? markupPercent = 30,
    PurchaseDraftLine? line,
  }) async {
    final catalog = _FakeCatalogRepository(siblings: [variant]);
    final purchase = _FakePurchaseRepository(markupPercent: markupPercent);
    final viewModel = PurchaseViewModel(catalog, purchase);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showPurchasePricingSheet(
                  context,
                  viewModel: viewModel,
                  line: line ?? cartonLine,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return _Harness(catalog: catalog, purchase: purchase);
  }

  Future<AppLocalizations> l10n() =>
      AppLocalizations.delegate.load(const Locale('ar'));

  Future<void> tapSave(WidgetTester tester) async {
    final strings = await l10n();
    await tester.tap(find.text(strings.changePricesSaveButton));
    await tester.pumpAndSettle();
  }

  testWidgets('prices against the base-unit cost, not the pack cost', (
    tester,
  ) async {
    final harness = await pumpSheet(tester);

    // 24 per carton / 12 base units = 2 per base unit.
    expect(harness.purchase.requestedUnitCost, 2.0);
    // The product id is forwarded so the backend can use its category markup.
    expect(harness.purchase.requestedProductId, 5);
  });

  testWidgets('lists the pack alongside the variant, with its own price', (
    tester,
  ) async {
    await pumpSheet(tester);
    final strings = await l10n();

    // The pack section is below the fold in the test viewport; scrolling to it
    // is how the pack rows get built.
    await tester.dragUntilVisible(
      find.text(strings.pricingSheetPackSectionTitle),
      find.byType(SingleChildScrollView).first,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.text(strings.pricingSheetPackSectionTitle), findsOneWidget);
    // The carton's own price (26.00), which the old dialog could not reach.
    expect(find.widgetWithText(TextFormField, '26.00'), findsOneWidget);
    // And the variant's base-unit price beside it.
    expect(find.widgetWithText(TextFormField, '10.00'), findsOneWidget);
  });

  testWidgets('saving without touching anything writes nothing', (
    tester,
  ) async {
    final harness = await pumpSheet(tester);

    await tapSave(tester);

    expect(harness.catalog.repricedPrices, isNull);
    expect(harness.catalog.repricedUnitPrices, isNull);
  });

  testWidgets('a markup chip reprices the variant AND the pack together', (
    tester,
  ) async {
    final harness = await pumpSheet(tester);
    final strings = await l10n();

    // The shop's own median markup: 30% over cost.
    await tester.tap(find.text(strings.pricingSheetSuggestedMarkupChip('30')));
    await tester.pumpAndSettle();
    await tapSave(tester);

    // Base: 2 x 1.30 = 2.60, snapped to the quarter-dinar step -> 2.50.
    expect(harness.catalog.repricedPrices, {11: 2.5});
    // Carton: 24 x 1.30 = 31.20, snapped -> 31.25. The whole point: one tap
    // keeps the wholesale price in step with the piece price.
    expect(harness.catalog.repricedUnitPrices, {'carton': 31.25});
  });

  testWidgets('handing a pack back to derived sends an explicit null', (
    tester,
  ) async {
    final harness = await pumpSheet(tester);
    final strings = await l10n();

    final derive = find.text(strings.pricingSheetUseDerivedButton);
    await tester.ensureVisible(derive);
    await tester.pumpAndSettle();
    await tester.tap(derive);
    await tester.pumpAndSettle();
    await tapSave(tester);

    expect(harness.catalog.repricedUnitPrices, containsPair('carton', isNull));
    expect(harness.catalog.repricedPrices, isEmpty);
  });

  testWidgets('no suggestion chip when the shop lacks pricing data', (
    tester,
  ) async {
    await pumpSheet(tester, markupPercent: null);

    expect(find.byIcon(Icons.auto_awesome), findsNothing);
  });
}

class _Harness {
  _Harness({required this.catalog, required this.purchase});

  final _FakeCatalogRepository catalog;
  final _FakePurchaseRepository purchase;
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository({this.siblings = const []}) : super(PosApiService());

  final List<ProductVariant> siblings;
  Map<int, double>? repricedPrices;
  Map<String, double?>? repricedUnitPrices;

  // The view model's constructor kicks off loadCatalog(); keep it inert.
  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => const Ok(ProductVariantPage(variants: [], hasMore: false));

  @override
  Future<Result<ProductVariantPage>> loadVariantsForProduct(
    int productId, {
    int page = 1,
  }) async => Ok(ProductVariantPage(variants: siblings, hasMore: false));

  @override
  Future<Result<Product>> setVariantPrices({
    required int productId,
    required Map<int, double> pricesByVariant,
    Map<String, double?> pricesByUnitCode = const {},
  }) async {
    repricedPrices = pricesByVariant;
    repricedUnitPrices = pricesByUnitCode;
    return Ok(Product(id: productId, name: 'p', quantityOnHand: 0));
  }
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository({this.markupPercent}) : super(PosApiService());

  final double? markupPercent;
  double? requestedUnitCost;
  int? requestedProductId;

  @override
  Future<Result<({double? suggestedPrice, double? markupPercent})>>
  loadPricingSuggestion(double unitCost, {int? productId}) async {
    requestedUnitCost = unitCost;
    requestedProductId = productId;
    return Ok((suggestedPrice: null, markupPercent: markupPercent));
  }

  @override
  Future<Result<List<VariantCostSummary>>> loadProductCostSummary(
    int productId,
  ) async => const Ok([]);
}
