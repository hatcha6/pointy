import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart'
    show generateAnalyticsEventId;
import '../../../data/models/stock_count.dart';
import '../../../data/models/stock_count_line.dart';
import '../../../data/repositories/stock_count_repository.dart';

/// Drives the finish screen: only the lines that differ, plus the manager-gated
/// Apply that commits the adjustments.
class StockCountReconciliationViewModel extends ChangeNotifier {
  StockCountReconciliationViewModel(
    this._repository, {
    required StockCount session,
  }) : _session = session,
       _applyIdempotencyKey = 'stock-count-apply:${generateAnalyticsEventId()}';

  final StockCountRepository _repository;

  StockCount _session;
  // Generated once and reused across retries so a flaky network never doubles
  // the adjustment.
  final String _applyIdempotencyKey;

  final List<StockCountLine> _lines = [];
  bool _isLoading = false;
  bool _hasLoadError = false;
  bool _isApplying = false;
  bool _applyError = false;
  StockCount? _appliedResult;

  StockCount get session => _session;
  List<StockCountLine> get lines => List.unmodifiable(_lines);
  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;
  bool get isApplying => _isApplying;
  bool get applyError => _applyError;
  StockCount? get appliedResult => _appliedResult;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadReconciliation(_session.id);
    switch (result) {
      case Ok<List<StockCountLine>>():
        _lines
          ..clear()
          ..addAll(result.value);
      case Error<List<StockCountLine>>():
        _lines.clear();
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<StockCount?> apply() async {
    if (_isApplying) {
      return null;
    }
    _isApplying = true;
    _applyError = false;
    notifyListeners();

    StockCount? applied;
    final result = await _repository.applyCount(
      _session.id,
      idempotencyKey: _applyIdempotencyKey,
    );
    switch (result) {
      case Ok<StockCount>():
        applied = result.value;
        _appliedResult = applied;
        _session = applied;
      case Error<StockCount>():
        _applyError = true;
    }

    _isApplying = false;
    notifyListeners();
    return applied;
  }

  void acknowledgeApplyError() {
    _applyError = false;
    notifyListeners();
  }
}
