import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/integration_recent_search.dart';
import '../../../data/repositories/integrations_repository.dart';

/// The searches that found something at one provider, newest first — what
/// the till's top-up screen shows before anybody has typed.
///
/// Paged by cursor and narrowed by [query], which the screen's debounced
/// search box sets once per pause in typing. The list is written to while it
/// is read (a search at any till lands at its head), which is why it pages
/// by cursor rather than by number.
class IntegrationRecentSearchesViewModel extends ChangeNotifier {
  IntegrationRecentSearchesViewModel({
    required IntegrationsRepository repository,
    required this.providerKey,
  }) : _repository = repository;

  final IntegrationsRepository _repository;
  final String providerKey;

  List<IntegrationRecentSearch> _searches = const [];
  String _query = '';
  String? _nextCursor;
  bool _hasMore = false;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasError = false;
  bool _loadMoreFailed = false;

  /// Bumped by every [load]. A response carrying an older value belongs to a
  /// query the cashier has already typed past, and is dropped.
  int _revision = 0;

  List<IntegrationRecentSearch> get searches => _searches;

  /// What the list is narrowed by. Empty means everything.
  String get query => _query;
  bool get hasMore => _hasMore;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;

  /// The first page failed, so there is nothing to show but a retry.
  bool get hasError => _hasError;

  /// A page after the first failed. Separate from [hasMore] on purpose: a
  /// failed request says nothing about whether more searches exist, and
  /// answering it by clearing [hasMore] would freeze the list at the rows it
  /// already has. The list offers a retry at its end instead.
  bool get loadMoreFailed => _loadMoreFailed;

  /// Narrow the list to [query]. A no-op when nothing changed, so a field
  /// reporting the same text twice costs no request.
  void setQuery(String query) {
    final next = query.trim();
    if (next == _query) return;
    _query = next;
    load();
  }

  /// Everything again, freshly read — however narrowed the list was, and
  /// even when it was not narrowed at all. After a lookup the search just
  /// run belongs at the top, and a list that skipped reloading because the
  /// query happened to be empty already would not show it there.
  Future<void> reset() {
    _query = '';
    return load();
  }

  /// The first page for the current [query].
  Future<void> load() async {
    final revision = ++_revision;
    _isLoading = true;
    // A page still in flight belongs to the old query and will be dropped
    // when it lands, so it must not keep the spinner at the bottom alive.
    _isLoadingMore = false;
    _hasError = false;
    _loadMoreFailed = false;
    notifyListeners();

    final result = await _repository.loadRecentSearches(
      providerKey: providerKey,
      search: _query,
    );
    if (revision != _revision) return;
    switch (result) {
      case Ok<IntegrationRecentSearchPage>(value: final page):
        _searches = page.searches;
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore;
      case Error<IntegrationRecentSearchPage>():
        // Rows from the previous query would not match this one, so they go
        // rather than sit under a search box that says something else.
        _searches = const [];
        _nextCursor = null;
        _hasMore = false;
        _hasError = true;
    }
    _isLoading = false;
    notifyListeners();
  }

  /// The page after the last one shown. Called by the list as the cashier
  /// nears its end, and by its retry button after a failure.
  Future<void> loadMore() async {
    final cursor = _nextCursor;
    if (_isLoading || _isLoadingMore || !_hasMore || cursor == null) return;
    final revision = _revision;
    _isLoadingMore = true;
    // Cleared here so the retry button, which calls straight back into this
    // method, puts the list back into loading rather than leaving the error.
    _loadMoreFailed = false;
    notifyListeners();

    final result = await _repository.loadRecentSearches(
      providerKey: providerKey,
      search: _query,
      cursor: cursor,
    );
    if (revision != _revision) return;
    switch (result) {
      case Ok<IntegrationRecentSearchPage>(value: final page):
        _searches = [..._searches, ...page.searches];
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore;
      case Error<IntegrationRecentSearchPage>():
        // The cursor and hasMore stay as they were, so the retry asks for the
        // very same page again.
        _loadMoreFailed = true;
    }
    _isLoadingMore = false;
    notifyListeners();
  }
}
