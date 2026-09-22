import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart'
    show generateAnalyticsEventId;
import '../../../data/models/stock_count.dart';
import '../../../data/models/stock_count_draft.dart';
import '../../../data/models/stock_count_line.dart';
import '../../../data/repositories/stock_count_repository.dart';
import '../../../data/services/api_error_detail.dart';

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

  /// What a *scanned* count found, which is four lists rather than a column of
  /// numbers: missing, unrecognised, standing in the wrong branch, and back
  /// from the dead. Each one is actionable on its own, which a variance
  /// quantity never is.
  StockCountScanReconciliation? _findings;
  bool _isLoading = false;
  bool _hasLoadError = false;
  bool _isApplying = false;
  bool _applyError = false;
  String _applyErrorMessage = '';
  StockCount? _appliedResult;

  StockCount get session => _session;
  List<StockCountLine> get lines => List.unmodifiable(_lines);
  StockCountScanReconciliation? get findings => _findings;

  /// Whether this count has anything identified to show. A shop that tracks
  /// nothing gets exactly the screen it had before.
  bool get hasFindings {
    final found = _findings;
    return found != null &&
        (found.scanned > 0 ||
            found.missing.isNotEmpty ||
            found.lots.isNotEmpty);
  }

  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;
  bool get isApplying => _isApplying;
  bool get applyError => _applyError;

  /// Why the server refused, in its own words, or empty when it gave none.
  ///
  /// A count is refused for exactly one interesting reason — applying it would
  /// drive named items below zero — and the server names them. "Could not
  /// apply" sends a manager back to a shelf of thousands with nothing to go on.
  String get applyErrorMessage => _applyErrorMessage;
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

    // Additive: a failure here leaves the ordinary variance list intact rather
    // than blocking the apply a shop is standing at the counter waiting for.
    final found = await _repository.loadScanReconciliation(_session.id);
    _findings = found is Ok<StockCountScanReconciliation> ? found.value : null;

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
        _applyErrorMessage = apiErrorDetail(result.exception, maxParts: 1);
    }

    _isApplying = false;
    notifyListeners();
    return applied;
  }

  void acknowledgeApplyError() {
    _applyError = false;
    _applyErrorMessage = '';
    notifyListeners();
  }
}
