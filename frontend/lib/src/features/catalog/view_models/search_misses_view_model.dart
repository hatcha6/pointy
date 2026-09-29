import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/search_miss.dart';
import '../../../data/repositories/search_miss_repository.dart';
import '../../../data/services/api_error_detail.dart';

/// How an action on one row went.
enum SearchMissActionOutcome {
  done,

  /// The server would not take that product: one a feature owns, or one
  /// archived since the picker listed it. Picking another one works.
  productRefused,

  /// Anything else — a dropped request, a row another device already
  /// handled. The row stays where it was.
  failed,

  /// An action on this row is still in flight; nothing was sent.
  busy,
}

/// The owner's "searched but not found" worklist: words the till, the catalog
/// or purchasing searched for and found nothing, most typed first.
///
/// Acting on a row takes it out of a list that no longer includes it —
/// resolving or dismissing from the open list, reopening from the others —
/// and that moves every later row up a place on the server too. A page counter
/// would then skip the rows that moved into pages already read, so
/// [loadMore] asks for the page holding the first row not shown yet, and drops
/// any row it already has.
class SearchMissesViewModel extends ChangeNotifier {
  SearchMissesViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine {
    unawaited(load());
  }

  final SearchMissRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  SearchMissFilter _filter = SearchMissFilter.open;
  List<SearchMiss> _misses = const [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasError = false;
  bool _hasMore = false;
  bool _loadMoreFailed = false;
  final Set<int> _busyIds = {};

  /// Rows per server page, learnt from a first page that has more after it.
  int _pageSize = 0;

  /// Pages to step past: each one came back holding only rows already shown,
  /// which happens when rows this list still holds were handled elsewhere.
  int _stalePages = 0;

  /// Bumped by every [load]. A response carrying an older value belongs to a
  /// filter the owner has already moved off, and is dropped.
  int _revision = 0;

  SearchMissFilter get filter => _filter;
  List<SearchMiss> get misses => _misses;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;

  /// The first page failed, so there is nothing to show but a retry.
  bool get hasError => _hasError;
  bool get hasMore => _hasMore;

  /// A page after the first failed. Separate from [hasMore] on purpose: a
  /// failed request says nothing about whether more rows exist, and clearing
  /// [hasMore] would freeze the list at the rows it already has.
  bool get loadMoreFailed => _loadMoreFailed;

  /// Whether an action on [miss] is still in flight.
  bool isBusy(SearchMiss miss) => _busyIds.contains(miss.id);

  void setFilter(SearchMissFilter filter) {
    if (filter == _filter) {
      return;
    }
    _filter = filter;
    // Rows of the old filter would sit under a chip that says something else.
    _misses = const [];
    _hasMore = false;
    unawaited(load());
  }

  /// The first page for the current [filter].
  Future<void> load() async {
    final revision = ++_revision;
    _isLoading = true;
    _isLoadingMore = false;
    _hasError = false;
    _loadMoreFailed = false;
    notifyListeners();

    final result = await _repository.loadMisses(filter: _filter);
    if (revision != _revision) {
      return;
    }
    switch (result) {
      case Ok<SearchMissPage>(value: final page):
        _misses = List.unmodifiable(page.misses);
        _hasMore = page.hasMore;
        _pageSize = page.hasMore ? page.misses.length : 0;
        _stalePages = 0;
      case Error<SearchMissPage>():
        _misses = const [];
        _hasMore = false;
        _hasError = true;
    }
    _isLoading = false;
    notifyListeners();
  }

  /// The rows after the last one shown. Called by the list as the owner nears
  /// its end, and by its retry button after a failure.
  Future<void> loadMore() async {
    if (_isLoading || _isLoadingMore || !_hasMore) {
      return;
    }
    final revision = _revision;
    _isLoadingMore = true;
    // Cleared here so the retry button, which calls straight back into this
    // method, puts the list back into loading rather than leaving the error.
    _loadMoreFailed = false;
    notifyListeners();

    final result = await _repository.loadMisses(
      page: _pageHoldingNextRow(),
      filter: _filter,
    );
    if (revision != _revision) {
      return;
    }
    switch (result) {
      case Ok<SearchMissPage>(value: final page):
        final shown = {for (final miss in _misses) miss.id};
        final unseen = [
          for (final miss in page.misses)
            if (!shown.contains(miss.id)) miss,
        ];
        _misses = List.unmodifiable([..._misses, ...unseen]);
        _hasMore = page.hasMore;
        _stalePages = unseen.isEmpty ? _stalePages + 1 : 0;
      case Error<SearchMissPage>():
        // hasMore and the rows stay as they were, so the retry asks for the
        // very same page again.
        _loadMoreFailed = true;
    }
    _isLoadingMore = false;
    notifyListeners();
  }

  /// From now on, a search for [miss]'s word finds [productId].
  Future<SearchMissActionOutcome> resolve(
    SearchMiss miss, {
    required int productId,
  }) {
    return _act(
      miss,
      () => _repository.resolve(miss.id, productId: productId),
      eventName: 'catalog.search_miss.resolved',
    );
  }

  Future<SearchMissActionOutcome> dismiss(SearchMiss miss) {
    return _act(
      miss,
      () => _repository.dismiss(miss.id),
      eventName: 'catalog.search_miss.dismissed',
    );
  }

  /// Back on the open list — to undo a dismissal, or to look at a word again.
  Future<SearchMissActionOutcome> reopen(SearchMiss miss) {
    return _act(
      miss,
      () => _repository.reopen(miss.id),
      eventName: 'catalog.search_miss.reopened',
    );
  }

  Future<SearchMissActionOutcome> _act(
    SearchMiss miss,
    Future<Result<SearchMiss>> Function() send, {
    required String eventName,
  }) async {
    if (!_busyIds.add(miss.id)) {
      return SearchMissActionOutcome.busy;
    }
    notifyListeners();

    final result = await send();
    _busyIds.remove(miss.id);
    final SearchMissActionOutcome outcome;
    switch (result) {
      case Ok<SearchMiss>(value: final updated):
        _place(updated);
        outcome = SearchMissActionOutcome.done;
        trackAuditEvent(
          _analyticsEngine,
          name: eventName,
          entityType: 'search_miss',
          entityId: updated.id,
          attributes: {
            'surface': updated.surface.name,
            'source': 'search_misses_screen',
          },
          metrics: {'count': updated.count},
        );
      case Error<SearchMiss>(:final exception):
        outcome =
            apiStatusCode(exception) == 400 &&
                apiErrorHasField(exception, 'product')
            ? SearchMissActionOutcome.productRefused
            : SearchMissActionOutcome.failed;
    }

    if (_misses.isEmpty && _hasMore && !_isLoading) {
      // The last row shown went while the server holds more: an empty list
      // would read "nothing to do", so fetch the next rows instead.
      unawaited(load());
    } else {
      notifyListeners();
    }
    return outcome;
  }

  /// Puts the server's answer where the current [filter] says it belongs:
  /// replaced in place, taken out, or put back where the server sorts it.
  void _place(SearchMiss updated) {
    final belongs = _filter.includes(updated.status);
    if (_misses.any((miss) => miss.id == updated.id)) {
      _misses = List.unmodifiable([
        for (final miss in _misses)
          if (miss.id != updated.id) miss else if (belongs) updated,
      ]);
      return;
    }
    if (!belongs) {
      return;
    }
    final at = _misses.indexWhere(
      (miss) => _compareWorklistOrder(updated, miss) < 0,
    );
    if (at == -1) {
      // Past every row loaded so far: the page that holds it will bring it.
      if (!_hasMore) {
        _misses = List.unmodifiable([..._misses, updated]);
      }
      return;
    }
    _misses = List.unmodifiable([..._misses]..insert(at, updated));
  }

  int _pageHoldingNextRow() {
    if (_pageSize <= 0) {
      return 2;
    }
    return _misses.length ~/ _pageSize + 1 + _stalePages;
  }
}

/// The server's order: most typed first, then most recently typed, then the
/// oldest row.
int _compareWorklistOrder(SearchMiss a, SearchMiss b) {
  final byCount = b.count.compareTo(a.count);
  if (byCount != 0) {
    return byCount;
  }
  final aSeen = a.lastSeenAt;
  final bSeen = b.lastSeenAt;
  if (aSeen != null && bSeen != null) {
    final bySeen = bSeen.compareTo(aSeen);
    if (bySeen != 0) {
      return bySeen;
    }
  }
  return a.id.compareTo(b.id);
}
