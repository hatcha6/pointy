import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bought_together_product.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/product_details_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_variant_form_sheet.dart';

/// Editing a variant shows the extra barcodes it already has as chips, and a
/// save sends the list as it now stands — the server replaces the stored one.
void main() {
  late List<Map<String, Object?>> patches;

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  const variant = ProductVariant(
    id: 11,
    productId: 1,
    sku: 'MILK-1',
    unitPrice: 4.5,
    barcode: '6281000000011',
    extraBarcodes: ['6281000000028', '7001'],
    isDefault: true,
  );

  Future<AppLocalizations> pumpSheet(WidgetTester tester) async {
    patches = [];
    const product = Product(
      id: 1,
      name: 'حليب',
      quantityOnHand: 0,
      trackingMode: TrackingMode.quantity,
      variants: [variant],
    );
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/identity-check/')) {
          return json(const {'sku': null, 'barcode': null});
        }
        if (request.method == 'PATCH' || request.method == 'PUT') {
          patches.add(jsonDecode(request.body) as Map<String, Object?>);
          return json({
            'id': 11,
            'product': 1,
            'sku': 'MILK-1',
            'unit_price': '4.50',
            'barcode': '6281000000011',
            'extra_barcodes': ['6281000000028'],
          });
        }
        return json(const {'results': <Object?>[], 'next': null});
      }),
    );
    final viewModel = ProductDetailsViewModel(
      _StubCatalogRepository(service, product),
      _StubPurchaseRepository(service),
      SaleRepository(service),
      product,
      shouldLoadSaleHistory: false,
      shouldLoadPurchaseHistory: false,
    );
    addTearDown(viewModel.dispose);
    await tester.binding.setSurfaceSize(const Size(700, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ProductVariantFormSheet(viewModel: viewModel, variant: variant),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.delegate.load(const Locale('ar'));
  }

  testWidgets('saved extras open as chips and a removal is saved', (
    tester,
  ) async {
    final l10n = await pumpSheet(tester);

    expect(find.text(l10n.variantExtraBarcodesLabel), findsOneWidget);
    expect(find.widgetWithText(InputChip, '6281000000028'), findsOneWidget);
    expect(find.widgetWithText(InputChip, '7001'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.widgetWithText(InputChip, '7001'),
        matching: find.byTooltip(l10n.variantExtraBarcodeRemoveTooltip),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.saveVariantButton));
    await tester.pumpAndSettle();

    expect(patches.single['barcode'], '6281000000011');
    expect(patches.single['extra_barcodes'], ['6281000000028']);
  });
}

class _StubCatalogRepository extends CatalogRepository {
  _StubCatalogRepository(super.service, this._product);

  final Product _product;

  @override
  Future<Result<Product>> loadProduct(int id) async => Ok(_product);

  @override
  Future<Result<List<BoughtTogetherProduct>>> loadBoughtTogether(
    int productId, {
    int limit = 8,
  }) async => const Ok([]);
}

class _StubPurchaseRepository extends PurchaseRepository {
  _StubPurchaseRepository(super.service);

  @override
  Future<Result<List<VariantCostSummary>>> loadProductCostSummary(
    int productId,
  ) async => const Ok([]);
}
