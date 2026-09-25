import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/warehouse_api_client.dart';

void main() {
  // The backend registers stock rows as `/api/stock/`. Both calls asked for
  // `/api/stock-items/`, which does not exist: every per-warehouse breakdown
  // and every transfer's product search answered 404 (field export,
  // 2026-09-25), and nothing had ever pinned the path.
  late List<Uri> requested;

  WarehouseApiClient client() {
    requested = [];
    final session = PosApiSession(
      client: MockClient((request) async {
        requested.add(request.url);
        return http.Response(
          jsonEncode({
            'results': [
              {
                'variant': 7,
                'variant_full_name': 'كابل',
                'variant_sku': 'CABLE',
                'warehouse': 2,
                'warehouse_name': 'المخزن',
                'quantity_on_hand': 4,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
      baseUrl: 'http://lan.test/api',
    );
    return WarehouseApiClient(session);
  }

  test('a product\'s stock by place is read from the stock endpoint', () async {
    final rows = await client().fetchStockByWarehouse(7);

    expect(requested.single.path, '/api/stock/');
    expect(requested.single.queryParameters['variant'], '7');
    expect(rows.single.warehouseName, 'المخزن');
    expect(rows.single.quantityOnHand, 4);
  });

  test('what a place holds is searched on the stock endpoint', () async {
    final rows = await client().searchStockAt(warehouseId: 2, search: 'كابل');

    expect(requested.single.path, '/api/stock/');
    expect(requested.single.queryParameters['warehouse'], '2');
    expect(requested.single.queryParameters['search'], 'كابل');
    expect(rows.single.variantSku, 'CABLE');
  });
}
