import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/missing_lot.dart';
import '../../../data/models/stock_batch.dart';
import '../../../data/models/stock_unit.dart';
import '../../../data/repositories/tracked_stock_repository.dart';

/// What a scan did on the worklist.
enum MissingLotScanOutcome { selected, alreadySelected, notFound }

/// The missing-lot worklist (§4.2): units a `serial → serial_batch` switch
/// left on the shelf with no lot, given one a variant at a time.
///
/// Worked like the opening identification run it sits beside: pick a
/// product, pick (or scan) the packs in front of you, say which lot they are,
/// repeat. Nothing moves — the lot's balance takes the units — so a wrong
/// choice is a wrong label, not a wrong stock figure.
class MissingLotsViewModel extends ChangeNotifier {
  MissingLotsViewModel(this._repository, {this.productId});

  final TrackedStockRepository _repository;

  /// One product's worklist, when it was opened from that product.
  final int? productId;

  List<MissingLotGroup> _groups = const [];
  bool _isLoadingGroups = false;
  bool _groupsFailed = false;
  int? _variantId;

  List<StockUnit> _units = const [];
  int _page = 1;
  bool _hasMore = false;
  bool _isLoadingUnits = false;
  bool _isLoadingMore = false;
  bool _unitsFailed = false;
  final Set<int> _selected = {};

  List<StockBatch> _lots = const [];
  bool _isLoadingLots = false;
  bool _isAssigning = false;
  Object? _assignError;
  bool _disposed = false;

  List<MissingLotGroup> get groups => _groups;
  bool get isLoadingGroups => _isLoadingGroups;
  bool get groupsFailed => _groupsFailed;
  int? get variantId => _variantId;
  MissingLotGroup? get group =>
      _groups.where((group) => group.variantId == _variantId).firstOrNull;

  List<StockUnit> get units => _units;
  bool get hasMore => _hasMore;
  bool get isLoadingUnits => _isLoadingUnits;
  bool get isLoadingMore => _isLoadingMore;
  bool get unitsFailed => _unitsFailed;
  Set<int> get selected => Set.unmodifiable(_selected);
  int get selectedCount => _selected.length;
  bool isSelected(int unitId) => _selected.contains(unitId);
  bool get allLoadedSelected =>
      _units.isNotEmpty && _units.every((unit) => _selected.contains(unit.id));

  /// The lots this variant already has, for the chooser. Shown newest-expiry
  /// last so the lot just delivered is at hand.
  List<StockBatch> get lots => _lots;
  bool get isLoadingLots => _isLoadingLots;
  bool get isAssigning => _isAssigning;
  Object? get assignError => _assignError;

  int get totalOutstanding =>
      _groups.fold<int>(0, (sum, group) => sum + group.count);

  Future<void> load() async {
    _isLoadingGroups = true;
    _groupsFailed = false;
    _notify();
    final result = await _repository.loadMissingLotGroups(productId: productId);
    _isLoadingGroups = false;
    switch (result) {
      case Ok<List<MissingLotGroup>>(:final value):
        _groups = value;
      case Error<List<MissingLotGroup>>():
        _groupsFailed = true;
    }
    final keep = _variantId;
    if (keep != null && _groups.any((group) => group.variantId == keep)) {
      _notify();
      return;
    }
    // One product to work is the common case from a product's own page;
    // making somebody tap the only row there is would be a step for nothing.
    _variantId = null;
    _units = const [];
    _selected.clear();
    _notify();
    if (_groups.length == 1) {
      await selectGroup(_groups.single.variantId);
    }
  }

  Future<void> selectGroup(int variantId) async {
    if (_variantId == variantId && _units.isNotEmpty) {
      return;
    }
    _variantId = variantId;
    _selected.clear();
    _units = const [];
    _lots = const [];
    _assignError = null;
    _notify();
    await Future.wait([_loadUnits(), _loadLots(variantId)]);
  }

  Future<void> _loadUnits() async {
    final variantId = _variantId;
    if (variantId == null) {
      return;
    }
    _isLoadingUnits = true;
    _unitsFailed = false;
    _page = 1;
    _notify();
    final result = await _repository.loadMissingLotUnits(variantId: variantId);
    if (variantId != _variantId) {
      return;
    }
    _isLoadingUnits = false;
    switch (result) {
      case Ok<StockUnitPage>(:final value):
        _units = value.units;
        _hasMore = value.hasNext;
      case Error<StockUnitPage>():
        _unitsFailed = true;
    }
    _notify();
  }

  Future<void> retryUnits() => _loadUnits();

  /// The next page, appended. A failed page keeps [hasMore] — it is not the
  /// end of the list, and treating it as one would hide the rest.
  Future<void> loadMore() async {
    final variantId = _variantId;
    if (variantId == null || _isLoadingMore || _isLoadingUnits || !_hasMore) {
      return;
    }
    _isLoadingMore = true;
    _notify();
    final result = await _repository.loadMissingLotUnits(
      variantId: variantId,
      page: _page + 1,
    );
    _isLoadingMore = false;
    if (variantId != _variantId) {
      return;
    }
    switch (result) {
      case Ok<StockUnitPage>(:final value):
        _page += 1;
        final known = {for (final unit in _units) unit.id};
        _units = [
          ..._units,
          ...value.units.where((unit) => !known.contains(unit.id)),
        ];
        _hasMore = value.hasNext;
        _unitsFailed = false;
      case Error<StockUnitPage>():
        _unitsFailed = true;
    }
    _notify();
  }

  Future<void> _loadLots(int variantId) async {
    _isLoadingLots = true;
    _notify();
    final result = await _repository.loadBatches(variantId: variantId);
    if (variantId != _variantId) {
      return;
    }
    _isLoadingLots = false;
    if (result case Ok<StockBatchPage>(:final value)) {
      _lots = [...value.batches]..sort(_byExpiry);
    }
    _notify();
  }

  static int _byExpiry(StockBatch a, StockBatch b) {
    final left = a.expiryDate;
    final right = b.expiryDate;
    if (left == null && right == null) {
      return a.id.compareTo(b.id);
    }
    if (left == null) {
      return 1;
    }
    if (right == null) {
      return -1;
    }
    return left.compareTo(right);
  }

  void toggle(int unitId) {
    if (!_selected.remove(unitId)) {
      _selected.add(unitId);
    }
    _notify();
  }

  void selectAllLoaded() {
    if (allLoadedSelected) {
      _selected.removeAll(_units.map((unit) => unit.id));
    } else {
      _selected.addAll(_units.map((unit) => unit.id));
    }
    _notify();
  }

  void clearSelection() {
    _selected.clear();
    _notify();
  }

  /// Either identifier, normalised the way the server normalises it, because
  /// a dual-SIM box shows whichever IMEI it shows.
  static String normalize(String value) =>
      value.toUpperCase().replaceAll(RegExp(r'[\s\-._/]'), '');

  /// A scan ticks the pack it reads: from the page already loaded, or — for
  /// one past it — by asking the server for that identifier.
  Future<MissingLotScanOutcome> scan(String raw) async {
    final code = normalize(raw);
    final variantId = _variantId;
    if (code.isEmpty || variantId == null) {
      return MissingLotScanOutcome.notFound;
    }
    bool matches(StockUnit unit) =>
        normalize(unit.code) == code || normalize(unit.secondaryCode) == code;
    for (final unit in _units) {
      if (matches(unit)) {
        return _pick(unit);
      }
    }
    final result = await _repository.loadMissingLotUnits(
      variantId: variantId,
      code: raw.trim(),
    );
    if (variantId != _variantId) {
      return MissingLotScanOutcome.notFound;
    }
    if (result case Ok<StockUnitPage>(:final value)) {
      for (final unit in value.units) {
        if (matches(unit)) {
          _units = [unit, ..._units.where((known) => known.id != unit.id)];
          return _pick(unit);
        }
      }
    }
    return MissingLotScanOutcome.notFound;
  }

  MissingLotScanOutcome _pick(StockUnit unit) {
    if (!_selected.add(unit.id)) {
      _notify();
      return MissingLotScanOutcome.alreadySelected;
    }
    _notify();
    return MissingLotScanOutcome.selected;
  }

  /// Puts the selected units into [lot]. On success they leave the worklist,
  /// and the product leaves it once its last pack has a lot.
  Future<LotAssignment?> assign(LotChoice lot) async {
    final variantId = _variantId;
    if (variantId == null || _selected.isEmpty || _isAssigning) {
      return null;
    }
    _isAssigning = true;
    _assignError = null;
    _notify();
    final chosen = _selected.toList()..sort();
    final result = await _repository.assignLot(
      variantId: variantId,
      unitIds: chosen,
      lot: lot,
    );
    _isAssigning = false;
    switch (result) {
      case Ok<LotAssignment>(:final value):
        final done = chosen.toSet();
        _units = _units
            .where((unit) => !done.contains(unit.id))
            .toList(growable: false);
        _selected.clear();
        _groups = [
          for (final group in _groups)
            if (group.variantId != variantId)
              group
            else if (group.count - value.assigned > 0)
              group.withCount(group.count - value.assigned),
        ];
        if (!_groups.any((group) => group.variantId == variantId)) {
          _variantId = null;
          _lots = const [];
        } else {
          // The lot it just went into is a choice for the next pile too.
          await _loadLots(variantId);
          if (_units.isEmpty && _hasMore) {
            await _loadUnits();
          }
        }
        _notify();
        return value;
      case Error<LotAssignment>(:final exception):
        _assignError = exception;
        _notify();
        return null;
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
