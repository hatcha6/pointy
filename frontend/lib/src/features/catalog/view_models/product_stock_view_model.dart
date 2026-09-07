import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/product.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/models/stock_item.dart';
import '../../../data/models/stock_movement.dart';
import '../../../data/models/stock_movement_page.dart';
import '../../../data/models/warehouse.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/warehouse_repository.dart';

class ProductStockViewModel extends ChangeNotifier {
  ProductStockViewModel(
    this._inventoryRepository,
    this._purchaseRepository,
    this.product, {
    WarehouseRepository? warehouseRepository,
    AnalyticsEngine? analyticsEngine,
  }) : _warehouseRepository = warehouseRepository,
       _analyticsEngine = analyticsEngine {
    load();
  }

  final InventoryRepository _inventoryRepository;
  final PurchaseRepository _purchaseRepository;
  final WarehouseRepository? _warehouseRepository;
  final Product product;
  final AnalyticsEngine? _analyticsEngine;

  StockItem? _stockItem;
  List<WarehouseStockRow> _byWarehouse = const [];
  List<StockMovement> _movements = [];
  List<ProductCostHistoryEntry> _costHistory = [];
  ProductMarginImpact? _marginImpact;
  VariantCostSummary? _variantCostSummary;
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
  VariantCostSummary? get variantCostSummary => _variantCostSummary;
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

  /// Where every unit of this product is sitting. Empty for a shop that has
  /// never opened a second place, which is what keeps the breakdown from
  /// appearing at all until it would say something.
  List<WarehouseStockRow> get byWarehouse => List.unmodifiable(_byWarehouse);

  /// True only when the answer to "how many" needs a second sentence.
  bool get isSplitAcrossPlaces => _byWarehouse.length > 1;

  /// Everything on hand, wherever it is.
  ///
  /// Summed across places rather than read off one row. The stock endpoint
  /// returns one row per (product, place), so taking the first — which is what
  /// this did while a product had exactly one — would report the store room's
  /// forty as the shop's total, or the showroom's three, depending on which
  /// came back first.
  int get quantityOnHand {
    if (_byWarehouse.isEmpty) {
      return _stockItem?.quantityOnHand ?? 0;
    }
    return _byWarehouse
        .fold<double>(0, (total, row) => total + row.quantityOnHand)
        .round();
  }

  Future<void> load() async {
    await Future.wait([loadStock(), loadMovements(), loadCostInsights()]);
  }

  Future<void> loadStock() async {
    _isLoadingStock = true;
    _errorMessage = null;
    notifyListeners();

    final variantId = product.variantId;
    final result = variantId == null
        ? await _inventoryRepository.loadStockForProduct(product.id)
        : await _inventoryRepository.loadStockForVariant(variantId);
    switch (result) {
      case Ok<StockItem?>():
        _stockItem = result.value;
      case Error<StockItem?>():
        _stockItem = null;
        _errorMessage = 'stock_load_error';
    }
    await _loadPlaces(variantId);

    _isLoadingStock = false;
    notifyListeners();
  }

  /// Best effort, and deliberately so: a shop with one place gains nothing
  /// from this call, and a failure here must not turn the stock panel into an
  /// error when the total is already known.
  Future<void> _loadPlaces(int? variantId) async {
    final repository = _warehouseRepository;
    if (repository == null || variantId == null) {
      return;
    }
    final result = await repository.loadStockByWarehouse(variantId);
    if (result case Ok<List<WarehouseStockRow>>()) {
      _byWarehouse = result.value
          .where((row) => row.quantityOnHand != 0 || row.quantityExpected != 0)
          .toList(growable: false);
    }
  }

  Future<void> loadMovements() async {
    _isLoadingMovements = true;
    _nextMovementPage = 1;
    _hasMoreMovements = true;
    _errorMessage = null;
    notifyListeners();

    final variantId = product.variantId;
    final result = variantId == null
        ? await _inventoryRepository.loadMovementsForProduct(
            product.id,
            page: _nextMovementPage,
          )
        : await _inventoryRepository.loadMovementsForVariant(
            variantId,
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

    final variantId = product.variantId;
    final historyFuture = _purchaseRepository.loadProductCostHistory(
      productId: product.id,
      variantId: variantId,
      page: _nextCostHistoryPage,
    );
    final marginFuture = variantId == null
        ? null
        : _purchaseRepository.loadProductMarginImpact(
            product.id,
            variantId: variantId,
          );
    final summaryFuture = variantId == null
        ? null
        : _purchaseRepository.loadProductCostSummary(product.id);
    final historyResult = await historyFuture;
    final marginResult = await marginFuture;
    final summaryResult = await summaryFuture;

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
    if (marginResult == null) {
      _marginImpact = null;
    } else {
      switch (marginResult) {
        case Ok<ProductMarginImpact?>():
          _marginImpact = marginResult.value;
        case Error<ProductMarginImpact?>():
          _marginImpact = null;
          _hasCostInsightsError = true;
      }
    }
    if (summaryResult == null) {
      _variantCostSummary = null;
    } else {
      switch (summaryResult) {
        case Ok<List<VariantCostSummary>>():
          _variantCostSummary = summaryResult.value
              .where((summary) => summary.variantId == variantId)
              .cast<VariantCostSummary?>()
              .firstWhere((summary) => summary != null, orElse: () => null);
        case Error<List<VariantCostSummary>>():
          _variantCostSummary = null;
      }
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
      variantId: product.variantId,
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

    final variantId = product.variantId;
    final result = variantId == null
        ? await _inventoryRepository.loadMovementsForProduct(
            product.id,
            page: _nextMovementPage,
          )
        : await _inventoryRepository.loadMovementsForVariant(
            variantId,
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
    required double quantity,
    required String note,
  }) async {
    if (_isSavingMovement) {
      return false;
    }
    final variantId = product.variantId;
    if (variantId == null) {
      _errorMessage = 'stock_movement_create_error';
      notifyListeners();
      return false;
    }

    _isSavingMovement = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _inventoryRepository.createMovement(
      StockMovementDraft(
        variant: variantId,
        movementType: movementType,
        quantity: quantity,
        note: note.trim(),
      ),
    );
    switch (result) {
      case Ok<StockMovement>():
        _trackStockMovementCreated(result.value);
        await load();
        _isSavingMovement = false;
        notifyListeners();
        return true;
      case Error<StockMovement>():
        _trackStockMovementFailed(
          movementType: movementType,
          quantity: quantity,
          note: note,
        );
        _errorMessage = 'stock_movement_create_error';
        _isSavingMovement = false;
        notifyListeners();
        return false;
    }
  }

  void _trackStockMovementCreated(StockMovement movement) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'catalog.stock_movement.created',
      entityType: 'stock_movement',
      entityId: movement.id,
      attributes: {
        'product_id': product.id,
        'product_name': product.name,
        if (product.variantId != null) 'variant_id': product.variantId,
        'movement_type': movement.movementType.apiValue,
        'note_present': movement.note.trim().isNotEmpty,
        'source': 'stock_movement_form',
      },
      metrics: {
        'quantity': movement.quantity,
        'on_hand_before': movement.onHandBefore,
        'on_hand_after': movement.onHandAfter,
        'committed_before': movement.committedBefore,
        'committed_after': movement.committedAfter,
        'expected_before': movement.expectedBefore,
        'expected_after': movement.expectedAfter,
      },
    );
  }

  void _trackStockMovementFailed({
    required StockMovementType movementType,
    required double quantity,
    required String note,
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'inventory.manual_movement.create_failed',
      severity: AnalyticsEventSeverity.warning,
      entityType: 'product',
      entityId: product.id,
      attributes: {
        'product_id': product.id,
        'product_name': product.name,
        if (product.variantId != null) 'variant_id': product.variantId,
        'movement_type': movementType.apiValue,
        'note_present': note.trim().isNotEmpty,
        'source': 'stock_movement_form',
      },
      metrics: {'quantity': quantity},
      flushImmediately: true,
    );
  }
}
