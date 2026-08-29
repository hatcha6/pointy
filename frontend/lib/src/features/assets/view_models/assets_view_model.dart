import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/customer_asset.dart';
import '../../../data/repositories/operations_repository.dart';

/// The registry list: one search box over every identity number the shop knows,
/// plus the wall-board question "what is in the shop right now?".
class AssetsViewModel extends ChangeNotifier {
  AssetsViewModel(this._repository);

  final OperationsRepository _repository;

  List<CustomerAsset> _assets = const [];
  String _searchQuery = '';
  bool _inShopOnly = false;
  int? _typeFilter;
  bool _isLoading = false;
  bool _hasLoadError = false;
  bool _hasMore = false;
  int _page = 1;
  bool _isLoadingMore = false;
  // Guards against a slow first page landing after a newer search, which would
  // repaint the list with results for a query the user has already replaced.
  int _requestToken = 0;

  List<CustomerAsset> get assets => _assets;
  String get searchQuery => _searchQuery;
  bool get inShopOnly => _inShopOnly;
  int? get typeFilter => _typeFilter;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasLoadError => _hasLoadError;
  bool get hasMore => _hasMore;

  bool get hasActiveFilters => _inShopOnly || _typeFilter != null;

  set searchQuery(String value) {
    if (_searchQuery == value) {
      return;
    }
    _searchQuery = value;
    notifyListeners();
    load();
  }

  set inShopOnly(bool value) {
    if (_inShopOnly == value) {
      return;
    }
    _inShopOnly = value;
    notifyListeners();
    load();
  }

  set typeFilter(int? value) {
    if (_typeFilter == value) {
      return;
    }
    _typeFilter = value;
    notifyListeners();
    load();
  }

  void clearFilters() {
    if (!hasActiveFilters && _searchQuery.isEmpty) {
      return;
    }
    _inShopOnly = false;
    _typeFilter = null;
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
      case Ok<CustomerAssetPage>():
        _assets = result.value.assets;
        _hasMore = result.value.hasMore;
      case Error<CustomerAssetPage>():
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
      case Ok<CustomerAssetPage>():
        _page += 1;
        _assets = [..._assets, ...result.value.assets];
        _hasMore = result.value.hasMore;
      case Error<CustomerAssetPage>():
        _hasLoadError = true;
    }
    _isLoadingMore = false;
    notifyListeners();
  }

  Future<Result<CustomerAssetPage>> _fetch({required int page}) {
    return _repository.loadCustomerAssets(
      search: _searchQuery,
      inShop: _inShopOnly ? true : null,
      assetType: _typeFilter?.toString(),
      page: page,
    );
  }
}
