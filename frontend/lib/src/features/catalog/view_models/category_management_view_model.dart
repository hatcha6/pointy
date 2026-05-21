import 'package:flutter/foundation.dart';

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
  CategoryManagementViewModel(this._catalogRepository) {
    loadCategories();
  }

  final CatalogRepository _catalogRepository;

  CatalogRepository get catalogRepository => _catalogRepository;

  final _rootBranch = _CategoryBranchState();
  final _childBranches = <int, _CategoryBranchState>{};
  final _expandedCategoryIds = <int>{};
  bool _isSaving = false;
  String? _errorMessage;

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
  bool get isSaving => _isSaving;
  bool get hasMoreCategories => _rootBranch.hasMore;
  String? get errorMessage => _errorMessage;

  bool isExpanded(ProductCategory category) {
    return _expandedCategoryIds.contains(category.id);
  }

  bool isLoadingChildren(ProductCategory category) {
    return _childBranches[category.id]?.isLoadingInitial ?? false;
  }

  Future<void> loadCategories() async {
    _rootBranch
      ..isLoadingInitial = true
      ..isLoadingMore = false
      ..hasMore = true
      ..hasError = false
      ..nextPage = 1;
    _errorMessage = null;
    notifyListeners();

    final result = await _catalogRepository.loadProductCategories(
      query: const ProductCategoryQuery(
        availability: ProductCategoryAvailabilityFilter.all,
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
        _errorMessage = 'category_load_error';
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
        _errorMessage = 'category_load_error';
    }

    _rootBranch.isLoadingMore = false;
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

  Future<void> loadMoreChildren(int parentId) {
    return _loadChildren(parentId, reset: false);
  }

  Future<void> retryLoadChildren(int parentId) {
    return _loadChildren(parentId, reset: true);
  }

  Future<bool> createCategory(ProductCategoryDraft draft) async {
    if (_isSaving) {
      return false;
    }
    _isSaving = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _catalogRepository.createProductCategory(draft);
    switch (result) {
      case Ok<ProductCategory>():
        await loadCategories();
        _isSaving = false;
        notifyListeners();
        return true;
      case Error<ProductCategory>():
        _errorMessage = 'category_create_error';
        _isSaving = false;
        notifyListeners();
        return false;
    }
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
        _errorMessage = 'category_load_error';
    }

    branch
      ..isLoadingInitial = false
      ..isLoadingMore = false;
    notifyListeners();
  }
}

class _CategoryBranchState {
  List<ProductCategory> categories = [];
  bool isLoadingInitial = false;
  bool isLoadingMore = false;
  bool hasMore = true;
  bool hasError = false;
  int nextPage = 1;
}
