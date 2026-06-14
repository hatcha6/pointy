import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/expense_category.dart';
import '../../../data/repositories/expense_repository.dart';

class ExpenseCategoriesViewModel extends ChangeNotifier {
  ExpenseCategoriesViewModel(
    this._repository, {
    AnalyticsEngine? analyticsEngine,
  }) : _analyticsEngine = analyticsEngine;

  final ExpenseRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  List<ExpenseCategory> _categories = const [];
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;

  List<ExpenseCategory> get categories => _categories;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadCategories();
    switch (result) {
      case Ok<List<ExpenseCategory>>():
        _categories = result.value;
      case Error<List<ExpenseCategory>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> createCategory(ExpenseCategoryDraft draft) {
    return _mutate(() async {
      final result = await _repository.createCategory(draft);
      switch (result) {
        case Ok<ExpenseCategory>():
          _track('settings.expense_category.created', result.value);
          return true;
        case Error<ExpenseCategory>():
          return false;
      }
    });
  }

  Future<bool> updateCategory(int categoryId, Map<String, Object?> changes) {
    return _mutate(() async {
      final result = await _repository.updateCategory(categoryId, changes);
      switch (result) {
        case Ok<ExpenseCategory>():
          _track('settings.expense_category.updated', result.value);
          return true;
        case Error<ExpenseCategory>():
          return false;
      }
    });
  }

  Future<bool> deleteCategory(ExpenseCategory category) {
    return _mutate(() async {
      final result = await _repository.deleteCategory(category.id);
      switch (result) {
        case Ok<void>():
          _track('settings.expense_category.deleted', category);
          return true;
        case Error<void>():
          return false;
      }
    });
  }

  Future<bool> _mutate(Future<bool> Function() operation) async {
    _isMutating = true;
    notifyListeners();

    final outcome = await operation();
    _isMutating = false;
    notifyListeners();
    await load();
    return outcome;
  }

  void _track(String name, ExpenseCategory category) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'expense_category',
      entityId: category.id,
      attributes: {'is_active': category.isActive, 'source': 'shop_settings'},
    );
  }
}
