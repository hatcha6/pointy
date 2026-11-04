import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../core/storage/app_key_value_store.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/models/reorder_queue.dart';
import '../../../data/repositories/reorder_repository.dart';

/// Remembers, per device, whether the queue includes what is about to run low.
class ReorderApproachingPreference {
  const ReorderApproachingPreference();

  static const _key = 'reorder_include_approaching';

  /// True unless someone switched it off, or the choice cannot be read.
  Future<bool> read() async {
    try {
      final store = await AppKeyValueStore.instance();
      return await store.getString(_key) != 'false';
    } on Object {
      return true;
    }
  }

  Future<void> write(bool value) async {
    try {
      final store = await AppKeyValueStore.instance();
      await store.setString(_key, value ? 'true' : 'false');
    } on Object {
      // The switch stays where it was put; the next start merely forgets it.
    }
  }
}

class ReorderViewModel extends ChangeNotifier {
  ReorderViewModel(
    this._repository, {
    ReorderApproachingPreference preference =
        const ReorderApproachingPreference(),
  }) : _preference = preference {
    unawaited(_start());
  }

  final ReorderRepository _repository;
  final ReorderApproachingPreference _preference;

  List<ReorderRow> _rows = const [];
  int _totalCount = 0;
  bool _isLoading = true;
  bool _hasError = false;
  bool _isCreating = false;
  bool _includeApproaching = true;
  int? _supplierId;
  String? _supplierName;
  String _search = '';
  final Set<int> _selected = {};
  final Map<int, double> _quantities = {};
  String? _pendingOrderKey;
  String? _pendingOrderFingerprint;
  int _loadToken = 0;
  bool _disposed = false;

  List<ReorderRow> get visibleRows => _search.trim().isEmpty
      ? _rows
      : _rows.where((row) => row.matches(_search)).toList(growable: false);

  bool get isLoading => _isLoading;
  bool get hasError => _hasError;
  bool get isCreating => _isCreating;
  bool get includeApproaching => _includeApproaching;
  int? get supplierId => _supplierId;
  String? get supplierName => _supplierName;
  String get search => _search;
  bool get isEmptyQueue => _rows.isEmpty;

  /// Rows the server left out past its cap.
  int get hiddenCount => _totalCount - _rows.length;

  int get selectedCount => _selected.length;
  bool isSelected(ReorderRow row) => _selected.contains(row.variantId);

  bool get allVisibleSelected {
    final rows = visibleRows;
    return rows.isNotEmpty &&
        rows.every((row) => _selected.contains(row.variantId));
  }

  double quantityOf(ReorderRow row) =>
      _quantities[row.variantId] ?? row.orderQuantity;

  /// An order needs someone to order from and something to order.
  bool get canCreateOrder =>
      _supplierId != null && _selected.isNotEmpty && !_isCreating;

  Future<void> _start() async {
    _includeApproaching = await _preference.read();
    if (!_disposed) {
      await load();
    }
  }

  Future<void> load() async {
    final token = ++_loadToken;
    _isLoading = true;
    _hasError = false;
    notifyListeners();

    final result = await _repository.loadQueue(
      supplierId: _supplierId,
      includeApproaching: _includeApproaching,
    );
    if (_disposed || token != _loadToken) {
      return;
    }
    switch (result) {
      case Ok<ReorderQueue>(:final value):
        _rows = value.rows;
        _totalCount = value.totalCount;
        // A ticked row that left the queue must not ride along unseen.
        final present = {for (final row in _rows) row.variantId};
        _selected.retainAll(present);
      case Error<ReorderQueue>():
        _rows = const [];
        _totalCount = 0;
        _selected.clear();
        _hasError = true;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> setSupplier({int? id, String? name}) async {
    if (_supplierId == id) {
      return;
    }
    _supplierId = id;
    _supplierName = name;
    await load();
  }

  Future<void> setIncludeApproaching(bool value) async {
    if (_includeApproaching == value) {
      return;
    }
    _includeApproaching = value;
    unawaited(_preference.write(value));
    await load();
  }

  void setSearch(String value) {
    if (value == _search) {
      return;
    }
    _search = value;
    notifyListeners();
  }

  void toggle(ReorderRow row) {
    if (!_selected.remove(row.variantId)) {
      _selected.add(row.variantId);
    }
    notifyListeners();
  }

  void toggleAllVisible() {
    final ids = visibleRows.map((row) => row.variantId);
    if (allVisibleSelected) {
      _selected.removeAll(ids);
    } else {
      _selected.addAll(ids);
    }
    notifyListeners();
  }

  /// Anything not above zero is ignored: the field goes back to what it was.
  void setQuantity(ReorderRow row, double quantity) {
    if (quantity <= 0 || quantity == quantityOf(row)) {
      return;
    }
    _quantities[row.variantId] = quantity;
    // Saying how many of something means wanting it.
    _selected.add(row.variantId);
    notifyListeners();
  }

  /// A draft for the ticked rows. The key survives a failure so a retry after
  /// a dropped response finds the order instead of making a second one, and is
  /// dropped once the order is safely in hand or the ticks change meaning.
  Future<PurchaseOrder?> createOrder() async {
    final supplierId = _supplierId;
    if (supplierId == null || _selected.isEmpty || _isCreating) {
      return null;
    }
    _isCreating = true;
    notifyListeners();

    final lines = [
      for (final row in _rows)
        if (_selected.contains(row.variantId))
          ReorderOrderLine(variantId: row.variantId, quantity: quantityOf(row)),
    ];
    final fingerprint = [
      supplierId,
      for (final line in lines) '${line.variantId}:${line.quantity}',
    ].join('|');
    if (_pendingOrderFingerprint != fingerprint) {
      _pendingOrderFingerprint = fingerprint;
      _pendingOrderKey = 'reorder-draft:${generateAnalyticsEventId()}';
    }
    final result = await _repository.createOrder(
      supplierId: supplierId,
      lines: lines,
      idempotencyKey: _pendingOrderKey,
    );
    if (_disposed) {
      return null;
    }
    _isCreating = false;
    switch (result) {
      case Ok<PurchaseOrder>(:final value):
        _pendingOrderKey = null;
        _pendingOrderFingerprint = null;
        _selected.clear();
        _quantities.clear();
        unawaited(load());
        return value;
      case Error<PurchaseOrder>():
        notifyListeners();
        return null;
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
