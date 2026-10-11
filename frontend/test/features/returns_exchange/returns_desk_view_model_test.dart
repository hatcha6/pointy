import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/return_search.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/invoices/view_models/invoice_details_view_model.dart';
import 'package:pointy_frontend/src/features/returns_exchange/view_models/returns_desk_view_model.dart';

/// A search answers late on a slow LAN. Whatever the cashier did since — a
/// newer search, opening an invoice — must not be replaced by that answer.
void main() {
  late _FakeSaleRepository repository;
  late ReturnsDeskViewModel viewModel;

  setUp(() {
    repository = _FakeSaleRepository();
    final service = PosApiService();
    viewModel = ReturnsDeskViewModel(
      repository,
      detailsFactory: (order) => InvoiceDetailsViewModel(
        repository,
        printingRepository: PrintingRepository(service),
        shopSettingsRepository: ShopSettingsRepository(service),
        catalogRepository: CatalogRepository(service),
        initialOrder: order,
      ),
    );
  });

  tearDown(() => viewModel.dispose());

  test('a slow search never replaces a newer one', () async {
    final slow = viewModel.search('حليب');
    final fast = viewModel.search('ارز');
    repository.searches['ارز']!.complete(Ok(_result(lineId: 2)));
    await fast;
    repository.searches['حليب']!.complete(Ok(_result(lineId: 1)));
    await slow;

    expect(viewModel.query, 'ارز');
    expect(viewModel.result!.lines.single.id, 2);
    expect(viewModel.isSearching, isFalse);
  });

  test('a search answering after an invoice opened leaves it open', () async {
    final search = viewModel.search('ارز');
    final open = viewModel.openInvoice(100, lineId: 1000);
    repository.orders[100]!.complete(Ok(_order(100)));
    await open;
    repository.searches['ارز']!.complete(Ok(_result(lineId: 1)));
    await search;

    expect(viewModel.details?.order.id, 100);
    expect(viewModel.preselectedLineId, 1000);
  });

  test(
    'a whole receipt opens its invoice with nothing to go back to',
    () async {
      final search = viewModel.search('R20261009000100');
      repository.searches['R20261009000100']!.complete(
        Ok(ReturnSearchResult(order: _order(100), windowHours: 72)),
      );
      await search;

      expect(viewModel.details?.order.id, 100);
      expect(viewModel.preselectedLineId, isNull);
      expect(viewModel.canGoBackToResults, isFalse);
    },
  );
}

class _FakeSaleRepository extends SaleRepository {
  _FakeSaleRepository() : super(PosApiService());

  final Map<String, Completer<Result<ReturnSearchResult>>> searches = {};
  final Map<int, Completer<Result<SaleOrder>>> orders = {};

  @override
  Future<Result<ReturnSearchResult>> searchReturns(String query) {
    return (searches[query] = Completer()).future;
  }

  @override
  Future<Result<SaleOrder>> loadOrder(int saleOrderId) {
    return (orders[saleOrderId] = Completer()).future;
  }
}

ReturnSearchResult _result({required int lineId}) {
  return ReturnSearchResult.fromJson({
    'order': null,
    'invoices': const <Object?>[],
    'lines': [
      {'id': lineId, 'order': 100, 'product_name': 'منتج', 'quantity': 1},
    ],
    'window_hours': 72,
  });
}

SaleOrder _order(int id) {
  return SaleOrder.fromJson({
    'id': id,
    'status': 'paid',
    'lines': const <Object?>[],
    'payments': const <Object?>[],
    'subtotal': '0',
    'total': '0',
  });
}
