import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/product.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/models/stock_item.dart';
import '../../../data/models/stock_movement.dart';
import '../../../data/models/stock_movement_page.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/repositories/purchase_repository.dart';

class ProductStockViewModel extends ChangeNotifier {
  ProductStockViewModel(
    this._inventoryRepository,
    this._purchaseRepository,
    this.product,
  ) {
    load();
  }

  final InventoryRepository _inventoryRepository;
  final PurchaseRepository _purchaseRepository;
  final Product product;

  StockItem? _stockItem;
  List<StockMovement> _movements = [];
  List<ProductCostHistoryEntry> _costHistory = [];
  ProductMarginImpact? _marginImpact;
  bool _isLoadingStock = false;
  bool _isLoadingMovements = false;
  bool _isLoadingCostInsights = false;
  bool _isLoadingMoreMovements = false;
  bool _isLoadingMoreCostHistory = false;
  bool _isSavingMovement = false;
  bool _hasMoreMovements = true;
  bool _hasMoreCostHistory = true;
  int _nextMovementPage = 1;
  int _nextCostHistoryPage = 1;
  String? _errorMessage;
  bool _hasCostInsightsError = false;

  StockItem? get stockItem => _stockItem;
  List<StockMovement> get movements => List.unmodifiable(_movements);
  List<ProductCostHistoryEntry> get costHistory =>
      List.unmodifiable(_costHistory);
  ProductMarginImpact? get marginImpact => _marginImpact;
  bool get isLoadingStock => _isLoadingStock;
  bool get isLoadingMovements => _isLoadingMovements;
  bool get isLoadingCostInsights => _isLoadingCostInsights;
  bool get isLoadingMoreMovements => _isLoadingMoreMovements;
  bool get isLoadingMoreCostHistory => _isLoadingMoreCostHistory;
  bool get isSavingMovement => _isSavingMovement;
  bool get hasMoreMovements => _hasMoreMovements;
  bool get hasMoreCostHistory => _hasMoreCostHistory;
  String? get errorMessage => _errorMessage;
  bool get hasCostInsightsError => _hasCostInsightsError;

  int get quantityOnHand => _stockItem?.quantityOnHand ?? 0;

  Future<void> load() async {
    await Future.wait([loadStock(), loadMovements(), loadCostInsights()]);
  }

  Future<void> loadStock() async {
    _isLoadingStock = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _inventoryRepository.loadStockForProduct(product.id);
    switch (result) {
      case Ok<StockItem?>():
        _stockItem = result.value;
      case Error<StockItem?>():
        _stockItem = null;
        _errorMessage = 'stock_load_error';
    }

    _isLoadingStock = false;
    notifyListeners();
  }

  Future<void> loadMovements() async {
    _isLoadingMovements = true;
    _nextMovementPage = 1;
    _hasMoreMovements = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _inventoryRepository.loadMovementsForProduct(
      product.id,
      page: _nextMovementPage,
    );
    switch (result) {
      case Ok<StockMovementPage>():
        _movements = result.value.movements;
        _hasMoreMovements = result.value.hasMore;
        _nextMovementPage = 2;
      case Error<StockMovementPage>():
        _movements = [];
        _hasMoreMovements = false;
        _errorMessage = 'stock_movement_load_error';
    }

    _isLoadingMovements = false;
    notifyListeners();
  }

  Future<void> loadCostInsights() async {
    _isLoadingCostInsights = true;
    _hasCostInsightsError = false;
    _hasMoreCostHistory = true;
    _nextCostHistoryPage = 1;
    notifyListeners();

    final historyFuture = _purchaseRepository.loadProductCostHistory(
      productId: product.id,
      page: _nextCostHistoryPage,
    );
    final marginFuture = _purchaseRepository.loadProductMarginImpact(
      product.id,
    );
    final historyResult = await historyFuture;
    final marginResult = await marginFuture;

    switch (historyResult) {
      case Ok<ProductCostHistoryPage>():
        _costHistory = historyResult.value.entries;
        _hasMoreCostHistory = historyResult.value.hasMore;
        _nextCostHistoryPage = 2;
      case Error<ProductCostHistoryPage>():
        _costHistory = [];
        _hasMoreCostHistory = false;
        _hasCostInsightsError = true;
    }
    switch (marginResult) {
      case Ok<ProductMarginImpact?>():
        _marginImpact = marginResult.value;
      case Error<ProductMarginImpact?>():
        _marginImpact = null;
        _hasCostInsightsError = true;
    }

    _isLoadingCostInsights = false;
    notifyListeners();
  }

  Future<void> loadMoreCostHistory() async {
    if (_isLoadingCostInsights ||
        _isLoadingMoreCostHistory ||
        !_hasMoreCostHistory) {
      return;
    }

    _isLoadingMoreCostHistory = true;
    notifyListeners();

    final result = await _purchaseRepository.loadProductCostHistory(
      productId: product.id,
      page: _nextCostHistoryPage,
    );
    switch (result) {
      case Ok<ProductCostHistoryPage>():
        _costHistory = [..._costHistory, ...result.value.entries];
        _hasMoreCostHistory = result.value.hasMore;
        _nextCostHistoryPage += 1;
      case Error<ProductCostHistoryPage>():
        _hasMoreCostHistory = false;
        _hasCostInsightsError = true;
    }

    _isLoadingMoreCostHistory = false;
    notifyListeners();
  }

  Future<void> loadMoreMovements() async {
    if (_isLoadingMovements || _isLoadingMoreMovements || !_hasMoreMovements) {
      return;
    }

    _isLoadingMoreMovements = true;
    notifyListeners();

    final result = await _inventoryRepository.loadMovementsForProduct(
      product.id,
      page: _nextMovementPage,
    );
    switch (result) {
      case Ok<StockMovementPage>():
        _movements = [..._movements, ...result.value.movements];
        _hasMoreMovements = result.value.hasMore;
        _nextMovementPage += 1;
      case Error<StockMovementPage>():
        _errorMessage = 'stock_movement_load_error';
    }

    _isLoadingMoreMovements = false;
    notifyListeners();
  }

  Future<bool> createMovement({
    required StockMovementType movementType,
    required int quantity,
    required String note,
  }) async {
    if (_isSavingMovement) {
      return false;
    }

    _isSavingMovement = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _inventoryRepository.createMovement(
      StockMovementDraft(
        product: product.id,
        movementType: movementType,
        quantity: quantity,
        note: note.trim(),
      ),
    );
    switch (result) {
      case Ok<StockMovement>():
        await load();
        _isSavingMovement = false;
        notifyListeners();
        return true;
      case Error<StockMovement>():
        _errorMessage = 'stock_movement_create_error';
        _isSavingMovement = false;
        notifyListeners();
        return false;
    }
  }
}
