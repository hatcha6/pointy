import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/barcode_resolution.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';

Map<String, Object?> _variantJson({String barcode = '6291041500213'}) {
  return {
    'id': 11,
    'product': 5,
    'product_name': 'زيت محرك',
    'display_name': 'زيت محرك',
    'full_name': 'زيت محرك',
    'sku': 'OIL-1',
    'unit_price': '12.50',
    'barcode': barcode,
    'quantity_on_hand': 8,
    'is_default': true,
    'is_active': true,
  };
}

void main() {
  late int requests;

  PosApiService serviceWith({required String version}) {
    requests = 0;
    return PosApiService(
      client: MockClient((request) async {
        requests += 1;
        final body = request.url.path.endsWith('/product-variants/')
            ? {
                'count': 1,
                'next': null,
                'results': [_variantJson()],
              }
            : {'count': 1, 'next': null, 'results': []};
        return http.Response.bytes(
          utf8.encode(jsonEncode(body)),
          200,
          headers: {'x-pointy-catalog-version': version},
        );
      }),
      baseUrl: 'http://pointy.test/api',
    );
  }

  test('repeat scans of the same barcode are served locally', () async {
    final repository = CatalogRepository(serviceWith(version: '7'));

    final first = await repository.resolveBarcode('6291041500213');
    final second = await repository.resolveBarcode('6291041500213');

    expect(requests, 1);
    expect(first, isA<Ok<BarcodeResolution?>>());
    final resolution = (second as Ok<BarcodeResolution?>).value;
    expect(resolution?.variant.sku, 'OIL-1');
  });

  test('not-found scans are cached too', () async {
    final service = PosApiService(
      client: MockClient((request) async {
        requests += 1;
        return http.Response(
          jsonEncode({'count': 0, 'next': null, 'results': []}),
          200,
          headers: {'x-pointy-catalog-version': '7'},
        );
      }),
      baseUrl: 'http://pointy.test/api',
    );
    requests = 0;
    final repository = CatalogRepository(service);

    final first = await repository.resolveBarcode('0000000');
    final baseline = requests;
    final second = await repository.resolveBarcode('0000000');

    expect((first as Ok<BarcodeResolution?>).value, isNull);
    expect((second as Ok<BarcodeResolution?>).value, isNull);
    expect(requests, baseline);
  });

  test('a catalog-version change invalidates cached scans', () async {
    var version = '7';
    requests = 0;
    final service = PosApiService(
      client: MockClient((request) async {
        requests += 1;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'count': 1,
              'next': null,
              'results': [_variantJson()],
            }),
          ),
          200,
          headers: {'x-pointy-catalog-version': version},
        );
      }),
      baseUrl: 'http://pointy.test/api',
    );
    final repository = CatalogRepository(service);

    await repository.resolveBarcode('6291041500213');
    expect(requests, 1);

    // Any other response (a discount preview, a checkout) pushing a newer
    // version orphans the cached resolution.
    version = '8';
    await service.fetchProducts(query: const ProductQuery(), page: 1);
    final requestsAfterListFetch = requests;

    await repository.resolveBarcode('6291041500213');
    expect(requests, requestsAfterListFetch + 1);
  });

  test('repeat product searches are served locally', () async {
    final repository = CatalogRepository(serviceWith(version: '7'));
    const query = ProductQuery(search: 'فلتر');

    final first = await repository.loadProducts(query: query, page: 1);
    final second = await repository.loadProducts(query: query, page: 1);

    expect(requests, 1);
    expect(first, isA<Ok<ProductPage>>());
    expect(second, isA<Ok<ProductPage>>());
  });

  test('different queries and pages never collide', () async {
    final repository = CatalogRepository(serviceWith(version: '7'));

    await repository.loadProducts(
      query: const ProductQuery(search: 'a'),
      page: 1,
    );
    await repository.loadProducts(
      query: const ProductQuery(search: 'b'),
      page: 1,
    );
    await repository.loadProducts(
      query: const ProductQuery(search: 'a'),
      page: 2,
    );

    expect(requests, 3);
  });
}
