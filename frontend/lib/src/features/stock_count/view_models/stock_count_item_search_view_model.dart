import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_page.dart';
import '../../../data/repositories/catalog_repository.dart';

/// Finding the thing in your hand in a catalog of tens of thousands of lines.
///
/// Shared by the counting screen's resting surface and by the "what is this
/// unidentified article?" picker, so both rank, page and fail the same way.
///
/// Debouncing belongs to the field (`DebouncedSearchField`); this owns the part
/// that has to be right regardless of how fast anyone types: a stale answer
/// never lands on a newer term. Without that guard, on a slow LAN the previous
/// word's results arrive last and stay on screen — the search looks broken
/// while being perfectly healthy.
class StockCountItemSearchViewModel extends ChangeNotifier {
  StockCountItemSearchViewModel(this._catalogRepository);

  final CatalogRepository _catalogRepository;

  String _term = '';
  List<ProductVariant> _results = const [];
  bool _isLoading = false;
  bool _hasError = false;
  bool _hasMore = false;
  int _page = 1;
  int _token = 0;
  bool _disposed = false;

  String get term => _term;
  List<ProductVariant> get results => _results;
  bool get isLoading => _isLoading;
  bool get hasError => _hasError;
  bool get hasMore => _hasMore;

  /// The row Enter picks. Deliberately "the best match", not "the only match":
  /// the server ranks an exact code above a name prefix above a contains, so
  /// typing a SKU and pressing Enter lands on that SKU even when the word also
  /// appears inside twenty product names.
  ProductVariant? get topMatch => _results.isEmpty ? null : _results.first;

  Future<void> search(String term) {
    _term = term.trim();
    return _run(page: 1, replace: true);
  }

  /// Next page of the current term.
  Future<void> loadMore() {
    if (_isLoading || !_hasMore) {
      return Future.value();
    }
    return _run(page: _page + 1, replace: false);
  }

  Future<void> retry() => _run(page: 1, replace: true);

  /// Resolves [term] and hands back its best match, running the query first
  /// when the results on screen are not that term's yet.
  ///
  /// This is the Enter key's half of the fast loop: the counter types and hits
  /// Enter without waiting for the debounce, so "what is on screen" is not a
  /// safe answer to "what did they mean".
  Future<ProductVariant?> resolveTopMatch(String term) async {
    final trimmed = term.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (_term != trimmed || _isLoading || _hasError) {
      await search(trimmed);
    }
    return topMatch;
  }

  /// Back to the browse list. Used between items so the next one starts from an
  /// empty field rather than the previous item's word.
  Future<void> reset() => search('');

  Future<void> _run({required int page, required bool replace}) async {
    final token = ++_token;
    _isLoading = true;
    _hasError = false;
    if (replace) {
      _results = const [];
      _hasMore = false;
    }
    _notify();

    final result = await _catalogRepository.loadProductVariants(
      query: ProductQuery(
        search: _term,
        availability: ProductAvailabilityFilter.active,
      ),
      page: page,
    );
    if (token != _token || _disposed) {
      // A newer term already answered, or is about to.
      return;
    }
    _isLoading = false;
    switch (result) {
      case Ok<ProductVariantPage>():
        // Service and made-to-order products hold no stock of their own, so
        // they are not countable — the server refuses a line for one.
        final countable = result.value.variants
            .where((variant) => !variant.isService && !variant.isPrepared)
            .toList(growable: false);
        _results = replace ? countable : [..._results, ...countable];
        _hasMore = result.value.hasMore;
        _page = page;
      case Error<ProductVariantPage>():
        if (replace) {
          _results = const [];
        }
        _hasError = true;
        _hasMore = false;
    }
    _notify();
  }

  void _notify() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
