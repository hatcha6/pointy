import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/operations_job.dart';
import '../../../data/repositories/operations_repository.dart';

/// Finished work, paginated.
///
/// Deliberately a separate screen — and a separate view model — from the board.
/// The board loads every open job at once because a shop has tens of them and
/// the kanban needs them all to lay out columns; history grows without bound,
/// so it pages. Mixing the two on one screen meant the board's "load everything"
/// applied to a year of completed repairs.
class JobHistoryViewModel extends ChangeNotifier {
  JobHistoryViewModel(this._repository);

  final OperationsRepository _repository;

  /// History opens on finished work. Cancelled jobs are one chip away, and
  /// open ones are deliberately unreachable from here — those live on the board.
  static const _defaultStatus = OperationsJobStatus.completed;

  List<OperationsJob> _jobs = const [];
  OperationsJobStatus _statusFilter = _defaultStatus;
  OperationsJobType? _jobTypeFilter;
  String _searchQuery = '';
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasLoadError = false;
  bool _hasMore = false;
  int _page = 1;
  int _requestToken = 0;

  List<OperationsJob> get jobs => _jobs;
  OperationsJobStatus get statusFilter => _statusFilter;
  OperationsJobType? get jobTypeFilter => _jobTypeFilter;
  String get searchQuery => _searchQuery;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasLoadError => _hasLoadError;
  bool get hasMore => _hasMore;

  bool get hasActiveFilters =>
      _statusFilter != _defaultStatus || _jobTypeFilter != null;

  set searchQuery(String value) {
    if (_searchQuery == value) {
      return;
    }
    _searchQuery = value;
    notifyListeners();
    load();
  }

  set statusFilter(OperationsJobStatus value) {
    if (_statusFilter == value) {
      return;
    }
    _statusFilter = value;
    notifyListeners();
    load();
  }

  set jobTypeFilter(OperationsJobType? value) {
    if (_jobTypeFilter == value) {
      return;
    }
    _jobTypeFilter = value;
    notifyListeners();
    load();
  }

  void clearFilters() {
    if (!hasActiveFilters && _searchQuery.isEmpty) {
      return;
    }
    _statusFilter = _defaultStatus;
    _jobTypeFilter = null;
    _searchQuery = '';
    notifyListeners();
    load();
  }

  Future<void> load() async {
    final token = ++_requestToken;
    _isLoading = true;
    _hasLoadError = false;
    _page = 1;
    notifyListeners();

    final result = await _fetch(page: 1);
    if (token != _requestToken) {
      return;
    }
    switch (result) {
      case Ok<OperationsJobPage>():
        _jobs = result.value.jobs;
        _hasMore = result.value.hasMore;
      case Error<OperationsJobPage>():
        _hasLoadError = true;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadMore() async {
    if (_isLoading || _isLoadingMore || !_hasMore) {
      return;
    }
    final token = _requestToken;
    _isLoadingMore = true;
    notifyListeners();

    final result = await _fetch(page: _page + 1);
    if (token != _requestToken) {
      return;
    }
    switch (result) {
      case Ok<OperationsJobPage>():
        _page += 1;
        _jobs = [..._jobs, ...result.value.jobs];
        _hasMore = result.value.hasMore;
      case Error<OperationsJobPage>():
        _hasLoadError = true;
    }
    _isLoadingMore = false;
    notifyListeners();
  }

  Future<Result<OperationsJobPage>> _fetch({required int page}) {
    return _repository.loadJobs(
      status: _statusFilter,
      jobType: _jobTypeFilter,
      search: _searchQuery,
      page: page,
    );
  }
}
