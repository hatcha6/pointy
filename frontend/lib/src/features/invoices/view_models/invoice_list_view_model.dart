import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/models/sale_order_page.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/order_document_service.dart';

class InvoiceListViewModel extends ChangeNotifier {
  InvoiceListViewModel(
    this._saleRepository,
    this._printingRepository,
    this._shopSettingsRepository,
  ) {
    loadInvoices();
  }

  final SaleRepository _saleRepository;
  final PrintingRepository _printingRepository;
  final ShopSettingsRepository _shopSettingsRepository;

  List<SaleOrder> _invoices = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasLoadError = false;
  bool _hasMoreInvoices = true;
  int _nextPage = 1;
  SaleOrderQuery _query = const SaleOrderQuery();

  List<SaleOrder> get invoices => List.unmodifiable(_invoices);
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasLoadError => _hasLoadError;
  bool get hasMoreInvoices => _hasMoreInvoices;
  SaleOrderQuery get query => _query;

  Future<void> loadInvoices() async {
    _isLoading = true;
    _hasLoadError = false;
    _hasMoreInvoices = true;
    _nextPage = 1;
    notifyListeners();

    final result = await _saleRepository.loadOrders(
      query: _query,
      page: _nextPage,
    );
    switch (result) {
      case Ok<SaleOrderPage>():
        _invoices = result.value.orders;
        _hasMoreInvoices = result.value.hasMore;
        _nextPage = 2;
      case Error<SaleOrderPage>():
        _invoices = [];
        _hasLoadError = true;
        _hasMoreInvoices = false;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadMoreInvoices() async {
    if (_isLoading || _isLoadingMore || !_hasMoreInvoices) {
      return;
    }

    _isLoadingMore = true;
    notifyListeners();

    final result = await _saleRepository.loadOrders(
      query: _query,
      page: _nextPage,
    );
    switch (result) {
      case Ok<SaleOrderPage>():
        _invoices = [..._invoices, ...result.value.orders];
        _hasMoreInvoices = result.value.hasMore;
        _nextPage += 1;
      case Error<SaleOrderPage>():
        _hasLoadError = true;
        _hasMoreInvoices = false;
    }

    _isLoadingMore = false;
    notifyListeners();
  }

  Future<void> updateSearch(String search) async {
    if (search == _query.search) {
      return;
    }
    _query = _query.copyWith(search: search);
    await loadInvoices();
  }

  Future<void> applyQuery(SaleOrderQuery query) async {
    if (query == _query) {
      return;
    }
    _query = query;
    await loadInvoices();
  }

  Future<bool> printInvoice(SaleOrder invoice) async {
    final order = await _loadCompleteInvoice(invoice);
    if (order == null) {
      return false;
    }
    final result = await _printingRepository.printSaleInvoice(
      order: order,
      shopSettings: await _loadShopSettings(),
    );
    return result.isSuccess;
  }

  Future<OrderDocumentActionStatus> shareInvoice(SaleOrder invoice) async {
    final order = await _loadCompleteInvoice(invoice);
    if (order == null) {
      return OrderDocumentActionStatus.failed;
    }
    return _printingRepository.shareSaleInvoice(
      order: order,
      shopSettings: await _loadShopSettings(),
    );
  }

  Future<SaleOrder?> _loadCompleteInvoice(SaleOrder invoice) async {
    final result = await _saleRepository.loadOrder(invoice.id);
    return switch (result) {
      Ok<SaleOrder>(value: final order) => order,
      Error<SaleOrder>() => null,
    };
  }

  Future<ShopSettings?> _loadShopSettings() async {
    final result = await _shopSettingsRepository.loadSettings();
    return switch (result) {
      Ok<ShopSettings>(value: final settings) => settings,
      Error<ShopSettings>() => null,
    };
  }
}
