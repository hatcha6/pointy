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
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/product_details_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_variant_form_sheet.dart';

/// A new variant is filled in with the shop's next number, like a new
/// product. An existing variant is not: its saved SKU stays exactly as it is
/// unless somebody edits it by hand.
void main() {
  const existing = ProductVariant(
    id: 11,
    productId: 1,
    sku: 'TEA-1',
    unitPrice: 5,
  );

  Product buildProduct() => const Product(
    id: 1,
    name: 'شاي',
    quantityOnHand: 0,
    variants: [existing],
  );

  Future<({List<Map<String, Object?>> sent, List<Uri> nextSkuCalls})> pumpSheet(
    WidgetTester tester, {
    ProductVariant? variant,
  }) async {
    final sent = <Map<String, Object?>>[];
    final nextSkuCalls = <Uri>[];
    http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/next-sku/')) {
          nextSkuCalls.add(request.url);
          return json(const {'sku': '1042'});
        }
        if (path.endsWith('/identity-check/')) {
          return json(const {'sku': null, 'barcode': null});
        }
        if (request.method == 'POST' || request.method == 'PATCH') {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          sent.add(body);
          return json({
            'id': 11,
            'product': 1,
            'sku': body['sku'],
            'barcode': body['barcode'],
            'unit_price': body['unit_price'],
          }, request.method == 'POST' ? 201 : 200);
        }
        return json(const {'results': <Object?>[], 'next': null});
      }),
    );
    final viewModel = ProductDetailsViewModel(
      _StubCatalogRepository(service, buildProduct()),
      _StubPurchaseRepository(service),
      _StubSaleRepository(service),
      buildProduct(),
      shouldLoadSaleHistory: false,
      shouldLoadPurchaseHistory: false,
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ProductVariantFormSheet(viewModel: viewModel, variant: variant),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (sent: sent, nextSkuCalls: nextSkuCalls);
  }

  // In order: variant name, SKU, barcode, price.
  String fieldText(WidgetTester tester, int index) => tester
      .widget<TextFormField>(find.byType(TextFormField).at(index))
      .controller!
      .text;

  testWidgets('a new variant shows the SKU it will be saved with', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final calls = await pumpSheet(tester);

    expect(fieldText(tester, 1), '1042');

    await tester.tap(find.byTooltip(l10n.useSkuAsBarcodeTooltip));
    await tester.enterText(find.byType(TextFormField).at(3), '7');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.createVariantButton));
    await tester.pumpAndSettle();

    expect(calls.sent.single['sku'], '1042');
    expect(calls.sent.single['barcode'], '1042');
  });

  testWidgets('editing a variant leaves its saved SKU alone', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final calls = await pumpSheet(tester, variant: existing);

    expect(fieldText(tester, 1), 'TEA-1');
    expect(find.text(l10n.skuAutomaticHelper), findsNothing);

    await tester.tap(find.text(l10n.saveVariantButton));
    await tester.pumpAndSettle();

    expect(calls.sent.single['sku'], 'TEA-1');
    expect(calls.nextSkuCalls, isEmpty, reason: 'nothing to number');
  });

  testWidgets('the saved SKU can still be edited by hand', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final calls = await pumpSheet(tester, variant: existing);

    await tester.enterText(find.byType(TextFormField).at(1), 'TEA-2');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.saveVariantButton));
    await tester.pumpAndSettle();

    expect(calls.sent.single['sku'], 'TEA-2');
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

class _StubSaleRepository extends SaleRepository {
  _StubSaleRepository(super.service);
}
