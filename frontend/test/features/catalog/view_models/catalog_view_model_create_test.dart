import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/models/product_draft.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/catalog_view_model.dart';

/// The purchasing workspace opens the full product-creation workflow when a
/// scanned code matches nothing, then drops the created product's default
/// variant into the purchase order. That hinges on [CatalogViewModel.createProduct]
/// handing the freshly created [Product] back to its caller — this locks it.
void main() {
  test('createProduct returns the created product with its default variant', () async {
    final repository = CatalogRepository(
      PosApiService(
        baseUrl: 'http://pointy.test/api',
        client: MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path == '/api/products/') {
            return http.Response(
              jsonEncode({
                'id': 42,
                'name': 'Test Product',
                'default_variant': {
                  'id': 100,
                  'product': 42,
                  'sku': 'SKU1',
                  'barcode': '5000001',
                  'unit_price': 0,
                },
              }),
              201,
              headers: {'content-type': 'application/json'},
            );
          }
          // loadProducts() — fired by the constructor and again after create.
          return http.Response(
            jsonEncode({'results': <Object?>[], 'next': null}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
    );

    final viewModel = CatalogViewModel(repository);
    addTearDown(viewModel.dispose);

    final result = await viewModel.createProduct(
      const ProductDraft(
        name: 'Test Product',
        variantSku: 'SKU1',
        variantBarcode: '5000001',
        variantUnitPrice: 0,
        isActive: true,
        tracksExpiry: false,
      ),
    );

    expect(result.outcome, ProductCreateOutcome.created);
    expect(result.product, isNotNull);
    expect(result.product!.id, 42);
    expect(result.product!.name, 'Test Product');
    // The variant the purchase order line is built from.
    expect(result.product!.defaultVariant?.barcode, '5000001');
  });
}
