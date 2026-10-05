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

/// The variant editor is where a GTIN is set after the product exists — and
/// only where it means something: a lot-tracked product, or a variant that
/// already carries one.
void main() {
  late List<Map<String, Object?>> patches;
  late http.Response Function() answer;

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  const variant = ProductVariant(
    id: 11,
    productId: 1,
    sku: 'AMX-1',
    unitPrice: 12,
    isDefault: true,
  );

  Product product(TrackingMode mode, {ProductVariant v = variant}) => Product(
    id: 1,
    name: 'أموكسيسيلين',
    quantityOnHand: 0,
    trackingMode: mode,
    variants: [v],
  );

  Future<AppLocalizations> pumpSheet(
    WidgetTester tester, {
    required Product product,
    required ProductVariant editing,
  }) async {
    patches = [];
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/identity-check/')) {
          return json(const {'sku': null, 'barcode': null});
        }
        if (request.method == 'PATCH' || request.method == 'PUT') {
          patches.add(jsonDecode(request.body) as Map<String, Object?>);
          return answer();
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
          body: ProductVariantFormSheet(viewModel: viewModel, variant: editing),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.delegate.load(const Locale('ar'));
  }

  Finder gtinField(AppLocalizations l10n) =>
      find.widgetWithText(TextFormField, l10n.variantGtinLabel);

  testWidgets('a counted product never shows the field', (tester) async {
    final l10n = await pumpSheet(
      tester,
      product: product(TrackingMode.quantity),
      editing: variant,
    );
    expect(gtinField(l10n), findsNothing);
  });

  testWidgets('a GTIN already saved stays editable whatever the mode', (
    tester,
  ) async {
    const carrying = ProductVariant(
      id: 11,
      productId: 1,
      sku: 'AMX-1',
      unitPrice: 12,
      gtin: '04006381333931',
    );
    final l10n = await pumpSheet(
      tester,
      product: product(TrackingMode.quantity, v: carrying),
      editing: carrying,
    );
    expect(
      tester.widget<TextFormField>(gtinField(l10n)).controller!.text,
      '04006381333931',
    );
  });

  testWidgets('a lot-tracked variant saves its GTIN, and a clash is named', (
    tester,
  ) async {
    answer = () => json({
      'gtin': ['taken'],
      'conflicts': [
        {
          'field': 'gtin',
          'kind': 'variant',
          'target': 'variant',
          'value': '04006381333931',
          'product_name': 'باراسيتامول',
        },
      ],
    }, 400);
    final l10n = await pumpSheet(
      tester,
      product: product(TrackingMode.batch),
      editing: variant,
    );

    await tester.enterText(gtinField(l10n), '4006381333931');
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.saveVariantButton));
    await tester.pumpAndSettle();

    expect(patches.single['gtin'], '4006381333931');
    expect(find.text(l10n.gtinTakenError('باراسيتامول')), findsOne);
    expect(find.text(l10n.formFixHighlightedFieldsError), findsOne);
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
