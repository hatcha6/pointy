import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/product_category.dart';
import '../../../data/models/product_category_query.dart';
import '../../../data/repositories/catalog_repository.dart';

enum CategoryTreeItemType {
  category,
  childrenLoading,
  childrenLoadError,
  loadMoreChildren,
}

class CategoryTreeItem {
  const CategoryTreeItem.category(this.category, {required this.depth})
    : type = CategoryTreeItemType.category,
      parent = null;

  const CategoryTreeItem.childrenLoading(this.parent, {required this.depth})
    : type = CategoryTreeItemType.childrenLoading,
      category = null;

  const CategoryTreeItem.childrenLoadError(this.parent, {required this.depth})
    : type = CategoryTreeItemType.childrenLoadError,
      category = null;

  const CategoryTreeItem.loadMoreChildren(this.parent, {required this.depth})
    : type = CategoryTreeItemType.loadMoreChildren,
      category = null;

  final CategoryTreeItemType type;
  final ProductCategory? category;
  final ProductCategory? parent;
  final int depth;
}

class CategoryManagementViewModel extends ChangeNotifier {
  CategoryManagementViewModel(
    this._catalogRepository, {
    AnalyticsEngine? analyticsEngine,
  }) : _analyticsEngine = analyticsEngine {
    refreshAll();
  }

  final CatalogRepository _catalogRepository;
  final AnalyticsEngine? _analyticsEngine;

  CatalogRepository get catalogRepository => _catalogRepository;

  final _rootBranch = _CategoryBranchState();
  final _childBranches = <int, _CategoryBranchState>{};
  final _searchBranch = _CategoryBranchState();
  final _expandedCategoryIds = <int>{};

  List<ProductCategory> _quickAccess = [];
  bool _isLoadingQuickAccess = false;
  bool _quickAccessError = false;

  String _search = '';
  int _searchVersion = 0;

  bool _isSaving = false;
  String? _loadError;

  // -- tree --------------------------------------------------------------

  List<ProductCategory> get categories =>
      List.unmodifiable(_rootBranch.categories);

  List<CategoryTreeItem> get visibleItems {
    final items = <CategoryTreeItem>[];
    for (final category in _rootBranch.categories) {
      _appendCategory(items, category, depth: 0);
    }
    return List.unmodifiable(items);
  }

  bool get isLoading => _rootBranch.isLoadingInitial;
  bool get isLoadingMore => _rootBranch.isLoadingMore;
  bool get hasMoreCategories => _rootBranch.hasMore;
  bool get isEmpty =>
      !isLoading && _rootBranch.categories.isEmpty && !hasLoadError;
  bool get hasLoadError => _loadError == 'category_load_error';
  bool get isSaving => _isSaving;
  String? get loadError => _loadError;

  bool isExpanded(ProductCategory category) =>
      _expandedCategoryIds.contains(category.id);

  bool isLoadingChildren(ProductCategory category) =>
      _childBranches[category.id]?.isLoadingInitial ?? false;

  // -- quick access ------------------------------------------------------

  List<ProductCategory> get quickAccess => List.unmodifiable(_quickAccess);
  bool get isLoadingQuickAccess => _isLoadingQuickAccess;
  bool get quickAccessError => _quickAccessError;
  bool get hasQuickAccess => _quickAccess.isNotEmpty;

  // -- search ------------------------------------------------------------

  String get search => _search;
  bool get isSearching => _search.trim().isNotEmpty;
  List<ProductCategory> get searchResults =>
      List.unmodifiable(_searchBranch.categories);
  bool get isLoadingSearch => _searchBranch.isLoadingInitial;
  bool get isLoadingMoreSearch => _searchBranch.isLoadingMore;
  bool get hasMoreSearch => _searchBranch.hasMore;
  bool get hasSearchError => _searchBranch.hasError;
  bool get hasNoSearchResults =>
      isSearching &&
      !isLoadingSearch &&
      !hasSearchError &&
      _searchBranch.categories.isEmpty;

  // -- loading -----------------------------------------------------------

  Future<void> refreshAll() async {
    await Future.wait([loadCategories(), loadQuickAccess()]);
    if (isSearching) {
      await _loadSearch(reset: true);
    }
  }

  Future<void> loadCategories() async {
    _rootBranch
      ..isLoadingInitial = true
      ..isLoadingMore = false
      ..hasMore = true
      ..hasError = false
      ..nextPage = 1;
    if (_loadError == 'category_load_error') {
      _loadError = null;
    }
    notifyListeners();

    final result = await _catalogRepository.loadProductCategories(
      query: const ProductCategoryQuery(
        availability: ProductCategoryAvailabilityFilter.all,
        ordering: ProductCategoryOrdering.manual,
        rootOnly: true,
      ),
      page: _rootBranch.nextPage,
    );
    switch (result) {
      case Ok<ProductCategoryPage>():
        _rootBranch
          ..categories = result.value.categories
          ..hasMore = result.value.hasMore
          ..nextPage = 2
          ..hasError = false;
        _expandedCategoryIds.clear();
        _childBranches.clear();
      case Error<ProductCategoryPage>():
        _rootBranch
          ..categories = []
          ..hasMore = false
          ..hasError = true;
        _loadError = 'category_load_error';
    }

    _rootBranch.isLoadingInitial = false;
    notifyListeners();
  }

  Future<void> loadMoreCategories() async {
    if (_rootBranch.isLoadingInitial ||
        _rootBranch.isLoadingMore ||
        !_rootBranch.hasMore) {
      return;
    }

    _rootBranch.isLoadingMore = true;
    notifyListeners();

    final result = await _catalogRepository.loadProductCategories(
      query: const ProductCategoryQuery(
        availability: ProductCategoryAvailabilityFilter.all,
        ordering: ProductCategoryOrdering.manual,
        rootOnly: true,
      ),
      page: _rootBranch.nextPage,
    );
    switch (result) {
      case Ok<ProductCategoryPage>():
        _rootBranch
          ..categories = [..._rootBranch.categories, ...result.value.categories]
          ..hasMore = result.value.hasMore
          ..nextPage += 1
          ..hasError = false;
      case Error<ProductCategoryPage>():
        _rootBranch
          ..hasMore = false
          ..hasError = true;
        _loadError = 'category_load_error';
    }

    _rootBranch.isLoadingMore = false;
    notifyListeners();
  }

  Future<void> loadQuickAccess() async {
    _isLoadingQuickAccess = true;
    _quickAccessError = false;
    notifyListeners();

    final result = await _catalogRepository.loadQuickAccessCategories();
    switch (result) {
      case Ok<List<ProductCategory>>():
        _quickAccess = result.value;
        _quickAccessError = false;
      case Error<List<ProductCategory>>():
        _quickAccessError = true;
    }

    _isLoadingQuickAccess = false;
    notifyListeners();
  }

  Future<void> toggleExpanded(ProductCategory category) async {
    if (category.childrenCount == 0) {
      return;
    }

    if (_expandedCategoryIds.remove(category.id)) {
      notifyListeners();
      return;
    }

    _expandedCategoryIds.add(category.id);
    final branch = _childBranches.putIfAbsent(
      category.id,
      _CategoryBranchState.new,
    );
    notifyListeners();

    if (branch.categories.isEmpty && !branch.isLoadingInitial) {
      await _loadChildren(category.id, reset: true);
    }
  }

  Future<void> loadMoreChildren(int parentId) =>
      _loadChildren(parentId, reset: false);

  Future<void> retryLoadChildren(int parentId) =>
      _loadChildren(parentId, reset: true);

  // -- search ------------------------------------------------------------

  Future<void> applySearch(String query) async {
    final normalized = query.trim();
    if (normalized == _search) {
      return;
    }
    _search = normalized;
    if (normalized.isEmpty) {
      _searchVersion += 1;
      _searchBranch.reset();
      notifyListeners();
      return;
    }
    await _loadSearch(reset: true);
  }

  Future<void> loadMoreSearchResults() => _loadSearch(reset: false);

  Future<void> retrySearch() => _loadSearch(reset: true);

  Future<void> _loadSearch({required bool reset}) async {
    final searchSnapshot = _search;
    if (searchSnapshot.isEmpty) {
      return;
    }
    final version = ++_searchVersion;

    if (reset) {
      _searchBranch
        ..isLoadingInitial = true
        ..isLoadingMore = false
        ..hasMore = true
        ..hasError = false
        ..nextPage = 1;
    } else {
      if (_searchBranch.isLoadingInitial ||
          _searchBranch.isLoadingMore ||
          !_searchBranch.hasMore) {
        return;
      }
      _searchBranch
        ..isLoadingMore = true
        ..hasError = false;
    }
    notifyListeners();

    final result = await _catalogRepository.loadProductCategories(
      query: ProductCategoryQuery(
        search: searchSnapshot,
        availability: ProductCategoryAvailabilityFilter.all,
        ordering: ProductCategoryOrdering.name,
      ),
      page: _searchBranch.nextPage,
    );
    if (version != _searchVersion || searchSnapshot != _search) {
      return;
    }

    switch (result) {
      case Ok<ProductCategoryPage>():
        _searchBranch
          ..categories = reset
              ? result.value.categories
              : [..._searchBranch.categories, ...result.value.categories]
          ..hasMore = result.value.hasMore
          ..nextPage += 1
          ..hasError = false;
      case Error<ProductCategoryPage>():
        if (reset) {
          _searchBranch.categories = [];
        }
        _searchBranch
          ..hasMore = false
          ..hasError = true;
    }

    _searchBranch
      ..isLoadingInitial = false
      ..isLoadingMore = false;
    notifyListeners();
  }

  // -- mutations ---------------------------------------------------------

  Future<bool> createCategory(ProductCategoryDraft draft) async {
    if (_isSaving) {
      return false;
    }
    _isSaving = true;
    notifyListeners();

    final result = await _catalogRepository.createProductCategory(draft);
    switch (result) {
      case Ok<ProductCategory>(value: final category):
        _trackCategoryEvent('catalog.category.created', category, draft);
        await _reloadAfterMutation();
        _isSaving = false;
        notifyListeners();
        return true;
      case Error<ProductCategory>():
        _isSaving = false;
        notifyListeners();
        return false;
    }
  }

  Future<bool> updateCategory(
    ProductCategory original,
    ProductCategoryDraft draft,
  ) async {
    if (_isSaving) {
      return false;
    }
    _isSaving = true;
    notifyListeners();

    final result = await _catalogRepository.updateProductCategory(
      id: original.id,
      draft: draft,
    );
    switch (result) {
      case Ok<ProductCategory>(value: final category):
        _trackCategoryEvent('catalog.category.updated', category, draft);
        await _reloadAfterMutation();
        _isSaving = false;
        notifyListeners();
        return true;
      case Error<ProductCategory>():
        _isSaving = false;
        notifyListeners();
        return false;
    }
  }

  Future<bool> deleteCategory(ProductCategory category) async {
    final result = await _catalogRepository.deleteProductCategory(category.id);
    switch (result) {
      case Ok<void>():
        _trackCategoryDeleted(category);
        await _reloadAfterMutation();
        notifyListeners();
        return true;
      case Error<void>():
        return false;
    }
  }

  /// Pin/unpin a category from the quick-access strip. Optimistic: the tree and
  /// the strip update immediately and reconcile with the server, so browsing
  /// state (expanded branches) is preserved.
  Future<bool> toggleQuickAccess(ProductCategory category) async {
    final desired = !category.isQuickAccess;
    final optimistic = category.copyWith(isQuickAccess: desired);
    _replaceCategoryEverywhere(optimistic);
    if (desired) {
      if (!_quickAccess.any((item) => item.id == category.id)) {
        _quickAccess = [..._quickAccess, optimistic];
      }
    } else {
      _quickAccess = _quickAccess
          .where((item) => item.id != category.id)
          .toList(growable: false);
    }
    notifyListeners();

    final result = await _catalogRepository.setCategoryQuickAccess(
      id: category.id,
      isQuickAccess: desired,
    );
    switch (result) {
      case Ok<ProductCategory>(value: final saved):
        _trackQuickAccessToggled(saved, desired);
        _replaceCategoryEverywhere(saved);
        await loadQuickAccess();
        return true;
      case Error<ProductCategory>():
        _replaceCategoryEverywhere(category);
        await loadQuickAccess();
        return false;
    }
  }

  Future<bool> reorderQuickAccess(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _quickAccess.length) {
      return false;
    }
    var targetIndex = newIndex;
    if (targetIndex > oldIndex) {
      targetIndex -= 1;
    }
    final reordered = [..._quickAccess];
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(targetIndex.clamp(0, reordered.length), moved);
    _quickAccess = reordered;
    notifyListeners();

    final result = await _catalogRepository.reorderQuickAccessCategories(
      reordered.map((category) => category.id).toList(growable: false),
    );
    if (result is Error<void>) {
      await loadQuickAccess();
      return false;
    }
    return true;
  }

  // -- internals ---------------------------------------------------------

  Future<void> _reloadAfterMutation() async {
    await loadCategories();
    await loadQuickAccess();
    if (isSearching) {
      await _loadSearch(reset: true);
    }
  }

  void _replaceCategoryEverywhere(ProductCategory updated) {
    List<ProductCategory> replaceIn(List<ProductCategory> source) => [
      for (final category in source)
        if (category.id == updated.id) updated else category,
    ];

    _rootBranch.categories = replaceIn(_rootBranch.categories);
    for (final branch in _childBranches.values) {
      branch.categories = replaceIn(branch.categories);
    }
    _searchBranch.categories = replaceIn(_searchBranch.categories);
  }

  void _appendCategory(
    List<CategoryTreeItem> items,
    ProductCategory category, {
    required int depth,
  }) {
    items.add(CategoryTreeItem.category(category, depth: depth));

    if (!_expandedCategoryIds.contains(category.id)) {
      return;
    }

    final branch = _childBranches[category.id];
    if (branch == null ||
        (branch.isLoadingInitial && branch.categories.isEmpty)) {
      items.add(CategoryTreeItem.childrenLoading(category, depth: depth + 1));
      return;
    }

    if (branch.hasError && branch.categories.isEmpty) {
      items.add(CategoryTreeItem.childrenLoadError(category, depth: depth + 1));
      return;
    }

    for (final child in branch.categories) {
      _appendCategory(items, child, depth: depth + 1);
    }

    if (branch.isLoadingMore) {
      items.add(CategoryTreeItem.childrenLoading(category, depth: depth + 1));
    } else if (branch.hasError) {
      items.add(CategoryTreeItem.childrenLoadError(category, depth: depth + 1));
    } else if (branch.hasMore) {
      items.add(CategoryTreeItem.loadMoreChildren(category, depth: depth + 1));
    }
  }

  Future<void> _loadChildren(int parentId, {required bool reset}) async {
    final branch = _childBranches.putIfAbsent(
      parentId,
      _CategoryBranchState.new,
    );

    if (reset) {
      branch
        ..isLoadingInitial = true
        ..isLoadingMore = false
        ..hasMore = true
        ..hasError = false
        ..nextPage = 1;
    } else {
      if (branch.isLoadingInitial || branch.isLoadingMore || !branch.hasMore) {
        return;
      }
      branch
        ..isLoadingMore = true
        ..hasError = false;
    }
    notifyListeners();

    final result = await _catalogRepository.loadProductCategories(
      query: ProductCategoryQuery(
        availability: ProductCategoryAvailabilityFilter.all,
        ordering: ProductCategoryOrdering.manual,
        parentId: parentId,
      ),
      page: branch.nextPage,
    );
    switch (result) {
      case Ok<ProductCategoryPage>():
        branch
          ..categories = reset
              ? result.value.categories
              : [...branch.categories, ...result.value.categories]
          ..hasMore = result.value.hasMore
          ..nextPage += 1
          ..hasError = false;
      case Error<ProductCategoryPage>():
        if (reset) {
          branch.categories = [];
        }
        branch
          ..hasMore = false
          ..hasError = true;
    }

    branch
      ..isLoadingInitial = false
      ..isLoadingMore = false;
    notifyListeners();
  }

  void _trackCategoryEvent(
    String name,
    ProductCategory category,
    ProductCategoryDraft draft,
  ) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'product_category',
      entityId: category.id,
      attributes: {
        'category_id': category.id,
        'category_name': category.name,
        if (draft.parentId != null) 'parent_id': draft.parentId,
        'is_active': category.isActive,
        'is_quick_access': category.isQuickAccess,
        'source': 'category_management',
      },
    );
  }

  void _trackCategoryDeleted(ProductCategory category) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'catalog.category.deleted',
      entityType: 'product_category',
      entityId: category.id,
      attributes: {
        'category_id': category.id,
        'category_name': category.name,
        'source': 'category_management',
      },
    );
  }

  void _trackQuickAccessToggled(ProductCategory category, bool isQuickAccess) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'catalog.category.quick_access_toggled',
      entityType: 'product_category',
      entityId: category.id,
      attributes: {
        'category_id': category.id,
        'category_name': category.name,
        'is_quick_access': isQuickAccess,
        'source': 'category_management',
      },
    );
  }
}

class _CategoryBranchState {
  List<ProductCategory> categories = [];
  bool isLoadingInitial = false;
  bool isLoadingMore = false;
  bool hasMore = true;
  bool hasError = false;
  int nextPage = 1;

  void reset() {
    categories = [];
    isLoadingInitial = false;
    isLoadingMore = false;
    hasMore = true;
    hasError = false;
    nextPage = 1;
  }
}
