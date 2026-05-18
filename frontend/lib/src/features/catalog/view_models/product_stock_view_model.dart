import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/product.dart';
import '../../../data/models/stock_item.dart';
import '../../../data/models/stock_movement.dart';
import '../../../data/models/stock_movement_page.dart';
import '../../../data/repositories/inventory_repository.dart';

class ProductStockViewModel extends ChangeNotifier {
  ProductStockViewModel(this._inventoryRepository, this.product) {
    load();
  }

  final InventoryRepository _inventoryRepository;
  final Product product;

  StockItem? _stockItem;
  List<StockMovement> _movements = [];
  bool _isLoadingStock = false;
  bool _isLoadingMovements = false;
  bool _isLoadingMoreMovements = false;
  bool _isSavingMovement = false;
  bool _hasMoreMovements = true;
  int _nextMovementPage = 1;
  String? _errorMessage;

  StockItem? get stockItem => _stockItem;
  List<StockMovement> get movements => List.unmodifiable(_movements);
  bool get isLoadingStock => _isLoadingStock;
  bool get isLoadingMovements => _isLoadingMovements;
  bool get isLoadingMoreMovements => _isLoadingMoreMovements;
  bool get isSavingMovement => _isSavingMovement;
  bool get hasMoreMovements => _hasMoreMovements;
  String? get errorMessage => _errorMessage;

  int get quantityOnHand => _stockItem?.quantityOnHand ?? 0;

  Future<void> load() async {
    await Future.wait([loadStock(), loadMovements()]);
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
