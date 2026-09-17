import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/stock_batch.dart';
import '../../../data/models/stock_unit.dart';
import '../../../data/repositories/tracked_stock_repository.dart';

/// The two lists a shop that identifies its stock actually works from.
///
/// One view model for both, because they are the same screen twice: a filtered,
/// searchable list of identified things with a detail behind each row. Splitting
/// them would duplicate the paging, the filters and the refresh, and the two
/// would drift.
class TrackedStockViewModel extends ChangeNotifier {
  TrackedStockViewModel(this._repository);

  final TrackedStockRepository _repository;

  List<StockUnit> _units = const [];
  List<StockBatch> _batches = const [];
  StockUnitSummary _summary = const StockUnitSummary();
  bool _isLoadingUnits = false;
  bool _isLoadingBatches = false;
  bool _hasUnitError = false;
  bool _hasBatchError = false;
  String _unitStatus = StockUnitStatus.inStock;
  String _unitSearch = '';
  String _batchStatus = '';
  bool _batchExpiredOnly = false;

  List<StockUnit> get units => _units;
  List<StockBatch> get batches => _batches;
  StockUnitSummary get summary => _summary;
  bool get isLoadingUnits => _isLoadingUnits;
  bool get isLoadingBatches => _isLoadingBatches;
  bool get hasUnitError => _hasUnitError;
  bool get hasBatchError => _hasBatchError;
  bool get unitsAreEmpty => _units.isEmpty;
  bool get batchesAreEmpty => _batches.isEmpty;
  String get unitStatus => _unitStatus;
  String get unitSearch => _unitSearch;
  String get batchStatus => _batchStatus;
  bool get batchExpiredOnly => _batchExpiredOnly;

  /// Articles the shop still owes an identifier for — the *capture later*
  /// worklist. Counted rather than listed here, because the point of the number
  /// is that somebody sees it is not zero.
  int get missingIdentifiers => _summary.missingIdentifiers;

  Future<void> loadUnits() async {
    _isLoadingUnits = true;
    notifyListeners();
    final result = await _repository.loadUnits(
      status: _unitStatus,
      code: _unitSearch,
    );
    switch (result) {
      case Ok<StockUnitPage>(:final value):
        _units = value.units;
        _hasUnitError = false;
      case Error<StockUnitPage>():
        _hasUnitError = true;
    }
    _isLoadingUnits = false;
    notifyListeners();
    unawaited(_loadSummary());
  }

  Future<void> _loadSummary() async {
    final result = await _repository.loadUnitSummary();
    if (result case Ok<StockUnitSummary>(:final value)) {
      _summary = value;
      notifyListeners();
    }
  }

  Future<void> loadBatches() async {
    _isLoadingBatches = true;
    notifyListeners();
    final result = await _repository.loadBatches(
      status: _batchStatus,
      isExpired: _batchExpiredOnly ? true : null,
    );
    switch (result) {
      case Ok<StockBatchPage>(:final value):
        _batches = value.batches;
        _hasBatchError = false;
      case Error<StockBatchPage>():
        _hasBatchError = true;
    }
    _isLoadingBatches = false;
    notifyListeners();
  }

  void setUnitStatus(String status) {
    if (_unitStatus == status) {
      return;
    }
    _unitStatus = status;
    unawaited(loadUnits());
  }

  void setUnitSearch(String term) {
    final trimmed = term.trim();
    if (_unitSearch == trimmed) {
      return;
    }
    _unitSearch = trimmed;
    unawaited(loadUnits());
  }

  void setBatchStatus(String status) {
    if (_batchStatus == status) {
      return;
    }
    _batchStatus = status;
    _batchExpiredOnly = false;
    unawaited(loadBatches());
  }

  void setBatchExpiredOnly(bool value) {
    if (_batchExpiredOnly == value) {
      return;
    }
    _batchExpiredOnly = value;
    _batchStatus = '';
    unawaited(loadBatches());
  }

  /// Stop-sale, everywhere, in one write — which is why the list can simply
  /// replace the row rather than reloading: nothing else changed.
  Future<bool> setQuarantine(StockBatch batch, {required bool locked}) async {
    final result = await _repository.setQuarantine(batch.id, locked: locked);
    if (result case Ok<StockBatch>(:final value)) {
      _batches = [
        for (final row in _batches)
          if (row.id == value.id) value else row,
      ];
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<List<StockAllocationEntry>> unitHistory(int unitId) async {
    final result = await _repository.loadUnitHistory(unitId);
    return switch (result) {
      Ok<List<StockAllocationEntry>>(:final value) => value,
      Error<List<StockAllocationEntry>>() => const [],
    };
  }

  Future<List<StockAllocationEntry>> batchHistory(int batchId) async {
    final result = await _repository.loadBatchHistory(batchId);
    return switch (result) {
      Ok<List<StockAllocationEntry>>(:final value) => value,
      Error<List<StockAllocationEntry>>() => const [],
    };
  }
}
