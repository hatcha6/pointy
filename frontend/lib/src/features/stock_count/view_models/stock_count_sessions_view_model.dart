import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/stock_count.dart';
import '../../../data/models/stock_count_draft.dart';
import '../../../data/repositories/stock_count_repository.dart';

/// Drives the stock-count sessions screen: the resumable in-progress count, the
/// history list, and starting a new count.
class StockCountSessionsViewModel extends ChangeNotifier {
  StockCountSessionsViewModel(this._repository);

  final StockCountRepository _repository;

  StockCount? _current;
  final List<StockCount> _sessions = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  bool _hasLoadError = false;
  bool _isStarting = false;
  int _nextPage = 1;

  StockCount? get current => _current;
  List<StockCount> get sessions => List.unmodifiable(_sessions);
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _hasMore;
  bool get hasLoadError => _hasLoadError;
  bool get isStarting => _isStarting;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    _hasMore = true;
    _nextPage = 1;
    notifyListeners();

    final currentResult = await _repository.loadCurrentCount();
    if (currentResult is Ok<StockCount?>) {
      _current = currentResult.value;
    }

    final result = await _repository.loadCounts(page: _nextPage);
    switch (result) {
      case Ok<StockCountPage>():
        _sessions
          ..clear()
          ..addAll(result.value.counts);
        _hasMore = result.value.hasMore;
        _nextPage = 2;
      case Error<StockCountPage>():
        _sessions.clear();
        _hasMore = false;
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadMore() async {
    if (_isLoading || _isLoadingMore || !_hasMore) {
      return;
    }
    _isLoadingMore = true;
    notifyListeners();

    final result = await _repository.loadCounts(page: _nextPage);
    switch (result) {
      case Ok<StockCountPage>():
        _sessions.addAll(result.value.counts);
        _hasMore = result.value.hasMore;
        _nextPage += 1;
      case Error<StockCountPage>():
        _hasMore = false;
    }

    _isLoadingMore = false;
    notifyListeners();
  }

  /// Starts (or resumes) a count. Returns the session on success, null on error.
  Future<StockCount?> startCount(StockCountStartDraft draft) async {
    _isStarting = true;
    notifyListeners();

    StockCount? started;
    final result = await _repository.startCount(draft);
    if (result is Ok<StockCount>) {
      started = result.value;
      _current = started;
    }

    _isStarting = false;
    notifyListeners();
    return started;
  }

  /// Clears the in-progress session locally (after it was applied/cancelled),
  /// then refreshes so the history reflects the new state.
  Future<void> refreshAfterSession() async {
    _current = null;
    await load();
  }
}
