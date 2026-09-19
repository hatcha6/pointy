import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/consignment.dart';
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
  // Paging state. Without it the screens showed page one and stopped: a shop
  // holding three thousand handsets could reach fifty of them, and the search
  // box searched only those fifty.
  int _unitPage = 1;
  int _batchPage = 1;
  bool _hasMoreUnits = false;
  bool _hasMoreBatches = false;
  bool _isLoadingMoreUnits = false;
  bool _isLoadingMoreBatches = false;
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
  bool get hasMoreUnits => _hasMoreUnits;
  bool get hasMoreBatches => _hasMoreBatches;
  bool get isLoadingMoreUnits => _isLoadingMoreUnits;
  bool get isLoadingMoreBatches => _isLoadingMoreBatches;
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
    _unitPage = 1;
    notifyListeners();
    final result = await _repository.loadUnits(
      status: _unitStatus,
      code: _unitSearch,
      page: _unitPage,
    );
    switch (result) {
      case Ok<StockUnitPage>(:final value):
        _units = value.units;
        _hasMoreUnits = value.hasNext;
        _hasUnitError = false;
      case Error<StockUnitPage>():
        _hasUnitError = true;
    }
    _isLoadingUnits = false;
    notifyListeners();
    unawaited(_loadSummary());
  }

  /// The next page, appended. Guarded against re-entry because the scroll
  /// extent that triggers it fires again while the request is in flight.
  Future<void> loadMoreUnits() async {
    if (_isLoadingMoreUnits || _isLoadingUnits || !_hasMoreUnits) {
      return;
    }
    _isLoadingMoreUnits = true;
    notifyListeners();
    final result = await _repository.loadUnits(
      status: _unitStatus,
      code: _unitSearch,
      page: _unitPage + 1,
    );
    switch (result) {
      case Ok<StockUnitPage>(:final value):
        _unitPage += 1;
        _units = [..._units, ...value.units];
        _hasMoreUnits = value.hasNext;
        _hasUnitError = false;
      case Error<StockUnitPage>():
        // A failed page must not look like the end of the list, or the shop
        // silently loses everything past it.
        _hasUnitError = true;
    }
    _isLoadingMoreUnits = false;
    notifyListeners();
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
    _batchPage = 1;
    notifyListeners();
    final result = await _repository.loadBatches(
      status: _batchStatus,
      isExpired: _batchExpiredOnly ? true : null,
      page: _batchPage,
    );
    switch (result) {
      case Ok<StockBatchPage>(:final value):
        _batches = value.batches;
        _hasMoreBatches = value.hasNext;
        _hasBatchError = false;
      case Error<StockBatchPage>():
        _hasBatchError = true;
    }
    _isLoadingBatches = false;
    notifyListeners();
  }

  Future<void> loadMoreBatches() async {
    if (_isLoadingMoreBatches || _isLoadingBatches || !_hasMoreBatches) {
      return;
    }
    _isLoadingMoreBatches = true;
    notifyListeners();
    final result = await _repository.loadBatches(
      status: _batchStatus,
      isExpired: _batchExpiredOnly ? true : null,
      page: _batchPage + 1,
    );
    switch (result) {
      case Ok<StockBatchPage>(:final value):
        _batchPage += 1;
        _batches = [..._batches, ...value.batches];
        _hasMoreBatches = value.hasNext;
        _hasBatchError = false;
      case Error<StockBatchPage>():
        _hasBatchError = true;
    }
    _isLoadingMoreBatches = false;
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

  /// One article, re-read. The detail screen asks after every write rather
  /// than patching its own copy: a unit's cost and status are decided by
  /// services, and a screen that guessed at the outcome would occasionally
  /// guess wrong.
  Future<StockUnit?> unitById(int unitId) async {
    final result = await _repository.loadUnit(unitId);
    return switch (result) {
      Ok<StockUnit>(:final value) => value,
      Error<StockUnit>() => null,
    };
  }

  Future<StockUnit?> reprice(int unitId, double price) async {
    final result = await _repository.repriceUnit(unitId, price);
    if (result case Ok<StockUnit>(:final value)) {
      _replaceUnit(value);
      return value;
    }
    return null;
  }

  Future<StockUnit?> writeOff(int unitId, String reason) async {
    final result = await _repository.writeOffUnit(unitId, reason: reason);
    if (result case Ok<StockUnit>(:final value)) {
      _replaceUnit(value);
      return value;
    }
    return null;
  }

  Future<bool> resendConsignorSms(int unitId) async {
    final result = await _repository.resendConsignorSms(unitId);
    return result is Ok<bool> && result.value;
  }

  void _replaceUnit(StockUnit unit) {
    _units = [
      for (final row in _units)
        if (row.id == unit.id) unit else row,
    ];
    notifyListeners();
  }

  Future<List<StockAllocationEntry>> unitHistory(int unitId) async {
    final result = await _repository.loadUnitHistory(unitId);
    return switch (result) {
      Ok<List<StockAllocationEntry>>(:final value) => value,
      Error<List<StockAllocationEntry>>() => const [],
    };
  }

  /// `allocations ∪ events`, in time order (§6.9).
  ///
  /// Falls back to empty rather than to an error: a unit whose movements
  /// render and whose price-change trail does not is a worse screen than one
  /// without the trail, and it is nowhere near as bad as no screen at all.
  Future<List<StockUnitTimelineEntry>> unitTimeline(int unitId) async {
    final result = await _repository.loadUnitTimeline(unitId);
    return switch (result) {
      Ok<List<StockUnitTimelineEntry>>(:final value) => value,
      Error<List<StockUnitTimelineEntry>>() => const [],
    };
  }

  Future<List<ConsignmentIncident>> unitIncidents(int unitId) async {
    final result = await _repository.loadUnitIncidents(unitId);
    return switch (result) {
      Ok<List<ConsignmentIncident>>(:final value) => value,
      Error<List<ConsignmentIncident>>() => const [],
    };
  }

  /// Write down what happened to somebody else's goods (§6.2.2).
  ///
  /// Returns the error text rather than swallowing it: the one refusal a
  /// person will actually hit here — the goods have already left the shelf —
  /// is worth reading.
  Future<String?> reportIncident(
    int unitId,
    ConsignmentIncidentDraft draft,
  ) async {
    final result = await _repository.reportIncident(unitId, draft);
    if (result case Ok<ConsignmentIncident>()) {
      final fresh = await _repository.loadUnit(unitId);
      if (fresh case Ok<StockUnit>(:final value)) {
        _replaceUnit(value);
      }
      notifyListeners();
      return null;
    }
    final failure = result is Error<ConsignmentIncident>
        ? result.exception.toString()
        : '';
    return failure.isEmpty ? null : failure;
  }

  Future<List<StockAllocationEntry>> batchHistory(int batchId) async {
    final result = await _repository.loadBatchHistory(batchId);
    return switch (result) {
      Ok<List<StockAllocationEntry>>(:final value) => value,
      Error<List<StockAllocationEntry>>() => const [],
    };
  }
}
