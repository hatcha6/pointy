import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/reprice_siblings_dialog.dart';

void main() {
  // A line bought by the carton (12 base units), costing 24 per carton — i.e.
  // 2 per base unit. Selling prices are stored per base unit, so the suggestion
  // must be based on 2, not 24.
  const variant = ProductVariant(id: 11, productId: 5, sku: 'A', unitPrice: 10);
  const cartonLine = PurchaseDraftLine(
    variant: variant,
    quantity: 1,
    unitCost: 24,
    unitCode: 'carton',
    unitLabel: 'Carton',
    unitFactor: 12,
  );

  Future<_Harness> pumpDialog(
    WidgetTester tester, {
    double? suggestedPrice,
    PurchaseDraftLine line = cartonLine,
  }) async {
    final catalog = _FakeCatalogRepository(siblings: const [variant]);
    final purchase = _FakePurchaseRepository(
      suggestedPrice: suggestedPrice,
      markupPercent: 30,
    );
    final viewModel = PurchaseViewModel(catalog, purchase);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showRepriceSiblingsDialog(
                  context,
                  viewModel: viewModel,
                  line: line,
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

  Future<void> tapSave(WidgetTester tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await tester.tap(find.text(l10n.changePricesSaveButton));
    await tester.pumpAndSettle();
  }

  testWidgets('bases the suggestion on the base-unit cost, not the pack cost', (
    tester,
  ) async {
    final harness = await pumpDialog(tester, suggestedPrice: 3);

    // 24 per carton / 12 base units = 2 per base unit.
    expect(harness.purchase.requestedUnitCost, 2.0);
    // The product id is forwarded so the backend can use its category markup.
    expect(harness.purchase.requestedProductId, 5);
  });

  testWidgets(
    'pre-fills the field with the current price, not the suggestion',
    (tester) async {
      await pumpDialog(tester, suggestedPrice: 3);

      // The editable field shows the variant's real current price (10.00), so a
      // straight save can never silently apply the recommendation.
      expect(find.widgetWithText(TextFormField, '10.00'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '3.00'), findsNothing);
    },
  );

  testWidgets('saving without touching anything writes nothing', (
    tester,
  ) async {
    final harness = await pumpDialog(tester, suggestedPrice: 3);

    await tapSave(tester);

    expect(
      harness.catalog.repricedPrices,
      isNull,
      reason: 'the recommendation must not be persisted unless applied',
    );
  });

  testWidgets(
    'applying the suggestion then saving writes the suggested price',
    (tester) async {
      final harness = await pumpDialog(tester, suggestedPrice: 3);

      await tester.tap(find.byIcon(Icons.auto_awesome));
      await tester.pumpAndSettle();
      await tapSave(tester);

      expect(harness.catalog.repricedPrices, {11: 3.0});
    },
  );

  testWidgets('no suggestion chip when the shop lacks pricing data', (
    tester,
  ) async {
    await pumpDialog(tester, suggestedPrice: null);

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
  }) async {
    repricedPrices = pricesByVariant;
    return Ok(Product(id: productId, name: 'p', quantityOnHand: 0));
  }
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository({this.suggestedPrice, this.markupPercent})
    : super(PosApiService());

  final double? suggestedPrice;
  final double? markupPercent;
  double? requestedUnitCost;
  int? requestedProductId;

  @override
  Future<Result<({double? suggestedPrice, double? markupPercent})>>
  loadPricingSuggestion(double unitCost, {int? productId}) async {
    requestedUnitCost = unitCost;
    requestedProductId = productId;
    return Ok((suggestedPrice: suggestedPrice, markupPercent: markupPercent));
  }
}
