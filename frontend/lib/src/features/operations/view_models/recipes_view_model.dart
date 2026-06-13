import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/bill_of_materials.dart';
import '../../../data/repositories/operations_repository.dart';

class RecipesViewModel extends ChangeNotifier {
  RecipesViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine;

  final OperationsRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  List<BillOfMaterials> _recipes = const [];
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;
  bool _hasMutationError = false;

  List<BillOfMaterials> get recipes => _recipes;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;
  bool get hasMutationError => _hasMutationError;

  Future<void> loadRecipes() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadAllBoms();
    switch (result) {
      case Ok<List<BillOfMaterials>>():
        _recipes = result.value;
      case Error<List<BillOfMaterials>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> save(BillOfMaterialsDraft draft) async {
    return _mutate(() async {
      final result = await _repository.saveBom(draft);
      switch (result) {
        case Ok<BillOfMaterials>():
          _trackRecipeEvent(
            draft.id == null
                ? 'operations.recipe.created'
                : 'operations.recipe.updated',
            result.value.id,
          );
          return true;
        case Error<BillOfMaterials>():
          _hasMutationError = true;
          return false;
      }
    });
  }

  Future<bool> delete(int bomId) async {
    return _mutate(() async {
      final result = await _repository.deleteBom(bomId);
      switch (result) {
        case Ok<void>():
          _trackRecipeEvent('operations.recipe.deleted', bomId);
          return true;
        case Error<void>():
          _hasMutationError = true;
          return false;
      }
    });
  }

  Future<bool> _mutate(Future<bool> Function() operation) async {
    _isMutating = true;
    _hasMutationError = false;
    notifyListeners();

    final outcome = await operation();
    _isMutating = false;
    notifyListeners();
    await loadRecipes();
    return outcome;
  }

  void _trackRecipeEvent(String name, int bomId) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'bill_of_materials',
      entityId: bomId,
      attributes: {'source': 'operations_ui'},
    );
  }
}
