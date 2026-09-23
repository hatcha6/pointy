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
import 'package:pointy_frontend/src/data/models/variant_option.dart';
import 'package:pointy_frontend/src/data/models/variant_option_value.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/product_details_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_variant_generation_sheet.dart';

/// Generating colours for a product that already sells: the variant it
/// already has becomes the first colour and keeps the SKU it was saved with;
/// every colour that is new takes the shop's next number.
void main() {
  const colourJson = {
    'id': 1,
    'code': 'color',
    'name': 'اللون',
    'display_order': 1,
    'is_active': true,
    'values': [
      {'id': 11, 'option': 1, 'code': 'red', 'name': 'أحمر', 'is_active': true},
      {
        'id': 12,
        'option': 1,
        'code': 'blue',
        'name': 'أزرق',
        'is_active': true,
      },
    ],
  };

  const colour = VariantOption(
    id: 1,
    code: 'color',
    name: 'اللون',
    displayOrder: 1,
    values: [
      VariantOptionValue(id: 11, optionId: 1, code: 'red', name: 'أحمر'),
      VariantOptionValue(id: 12, optionId: 1, code: 'blue', name: 'أزرق'),
    ],
  );

  const product = Product(
    id: 1,
    name: 'قميص',
    quantityOnHand: 0,
    variantOptions: [colour],
    variants: [
      ProductVariant(
        id: 21,
        productId: 1,
        sku: 'SHIRT-1',
        unitPrice: 20,
        isDefault: true,
      ),
    ],
  );

  testWidgets('new rows are numbered; the existing variant keeps its SKU', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    Map<String, Object?>? sent;
    http.Response json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/next-sku/')) {
          return json(const {'sku': '1042'});
        }
        if (path.contains('variant-options')) {
          return json(const {
            'results': [colourJson],
            'next': null,
          });
        }
        if (request.method == 'PATCH') {
          sent = jsonDecode(request.body) as Map<String, Object?>;
          return json(const {'id': 1, 'name': 'قميص', 'variants': []});
        }
        return json(const {'results': <Object?>[], 'next': null});
      }),
    );
    final viewModel = ProductDetailsViewModel(
      _StubCatalogRepository(service, product),
      _StubPurchaseRepository(service),
      _StubSaleRepository(service),
      product,
      shouldLoadSaleHistory: false,
      shouldLoadPurchaseHistory: false,
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ProductVariantGenerationSheet(viewModel: viewModel),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> tapVisible(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    await tapVisible(find.text(l10n.selectAllVariantOptionValues(2)));

    final shown = [
      for (final field in tester.widgetList<TextFormField>(
        find.byType(TextFormField),
      ))
        field.controller!.text,
    ];
    expect(shown, containsAll(['SHIRT-1', '1042']));

    // The sheet's title carries the same words; the button comes after it.
    await tapVisible(find.text(l10n.generateVariantsButton).last);

    final variants = (sent!['variants']! as List).cast<Map<String, Object?>>();
    expect(
      {for (final variant in variants) variant['id']: variant['sku']},
      {21: 'SHIRT-1', null: '1042'},
    );
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
