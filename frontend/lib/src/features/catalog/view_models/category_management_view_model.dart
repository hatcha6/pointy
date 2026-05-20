import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/product_category.dart';
import '../../../data/models/product_category_query.dart';
import '../../../data/repositories/catalog_repository.dart';

class CategoryManagementViewModel extends ChangeNotifier {
  CategoryManagementViewModel(this._catalogRepository) {
    loadCategories();
  }

  final CatalogRepository _catalogRepository;

  CatalogRepository get catalogRepository => _catalogRepository;

  List<ProductCategory> _categories = [];
  bool _isLoading = false;
  bool _isSaving = false;
  String? _errorMessage;

  List<ProductCategory> get categories => List.unmodifiable(_categories);
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  String? get errorMessage => _errorMessage;

  Future<void> loadCategories() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _catalogRepository.loadProductCategories(
      query: const ProductCategoryQuery(
        availability: ProductCategoryAvailabilityFilter.all,
      ),
    );
    switch (result) {
      case Ok<ProductCategoryPage>():
        _categories = result.value.categories;
      case Error<ProductCategoryPage>():
        _categories = [];
        _errorMessage = 'category_load_error';
    }

    _isLoading = false;
    notifyListeners();
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
}
