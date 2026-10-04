import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant_draft.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/product_details_view_model.dart';

/// Generating sizes saves the whole product, and the server writes every field
/// the PATCH carries: a blank currency or default unit there is a reset, not
/// an omission.
void main() {
  // A dollar-priced shirt, sold by the box and bought by the carton.
  const shirtJson = {
    'id': 1,
    'name': 'قميص',
    'unit': 'piece',
    'pricing_currency': 'USD',
    'default_sale_unit': 'box',
    'default_purchase_unit': 'carton',
    'units': [
      {'id': 70, 'unit': 'box', 'factor_to_base': '6'},
      {'id': 71, 'unit': 'carton', 'factor_to_base': '24'},
    ],
    'default_variant': {
      'id': 21,
      'product': 1,
      'sku': 'SHIRT-1',
      'unit_price': '82.20',
      'price_amount': '12.00',
      'is_default': true,
    },
  };

  test(
    'generating variants keeps the price currency and default units',
    () async {
      Map<String, Object?>? patched;
      final service = PosApiService(
        baseUrl: 'http://pointy.test/api',
        client: MockClient((request) async {
          Object body = const {'results': <Object?>[], 'next': null};
          if (request.url.path == '/api/products/1/') {
            if (request.method == 'PATCH') {
              patched = jsonDecode(request.body) as Map<String, Object?>;
            }
            body = shirtJson;
          }
          return http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final viewModel = ProductDetailsViewModel(
        CatalogRepository(service),
        PurchaseRepository(service),
        SaleRepository(service),
        const Product(id: 1, name: 'قميص', quantityOnHand: 0),
        shouldLoadSaleHistory: false,
        shouldLoadPurchaseHistory: false,
      );
      addTearDown(viewModel.dispose);
      await viewModel.loadProduct();
      expect(viewModel.product.pricingCurrency, 'USD');

      final saved = await viewModel.saveGeneratedVariants(
        variantOptionIds: const [1],
        variants: const [
          ProductVariantDraft(
            id: 21,
            productId: 1,
            sku: 'SHIRT-1',
            unitPrice: 82.2,
            isDefault: true,
            optionValueIds: [11],
          ),
          ProductVariantDraft(
            productId: 1,
            sku: 'SHIRT-2',
            unitPrice: 82.2,
            optionValueIds: [12],
          ),
        ],
      );
      // The loads the constructor started settle before the teardown.
      await pumpEventQueue();

      expect(saved, isTrue);
      expect(patched, isNotNull);
      expect(patched!['pricing_currency'], 'USD');
      expect(patched!['default_sale_unit'], 'box');
      expect(patched!['default_purchase_unit'], 'carton');
      expect(patched!['variants'], hasLength(2));
    },
  );
}
