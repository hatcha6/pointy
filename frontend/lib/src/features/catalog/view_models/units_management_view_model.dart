import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/unit_of_measure.dart';
import '../../../data/repositories/catalog_repository.dart';

/// Drives the units-of-measure management screen: loads the full (active +
/// inactive) registry and creates/updates/deletes/reorders units, reloading
/// from the server after every write.
class UnitsManagementViewModel extends ChangeNotifier {
  UnitsManagementViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine;

  final CatalogRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  List<UnitOfMeasure> _units = const [];
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;

  List<UnitOfMeasure> get units => _units;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;

  /// Units grouped by dimension, in the registry's display order, for sectioned
  /// rendering. Only dimensions that have at least one unit appear.
  Map<String, List<UnitOfMeasure>> get unitsByDimension {
    final grouped = <String, List<UnitOfMeasure>>{};
    for (final dimension in kUnitDimensions) {
      final inDimension = [
        for (final unit in _units)
          if (unit.dimension == dimension) unit,
      ];
      if (inDimension.isNotEmpty) {
        grouped[dimension] = inDimension;
      }
    }
    // Surface any unknown dimensions last so nothing is silently hidden.
    for (final unit in _units) {
      if (!kUnitDimensions.contains(unit.dimension)) {
        grouped.putIfAbsent(unit.dimension, () => []).add(unit);
      }
    }
    return grouped;
  }

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadAllUnits(activeOnly: false);
    switch (result) {
      case Ok<List<UnitOfMeasure>>():
        _units = result.value;
      case Error<List<UnitOfMeasure>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> createUnit(UnitOfMeasureDraft draft) {
    return _mutate(() async {
      final result = await _repository.createUnit(draft);
      switch (result) {
        case Ok<UnitOfMeasure>():
          _track('catalog.unit.created', result.value);
          return true;
        case Error<UnitOfMeasure>():
          return false;
      }
    });
  }

  Future<bool> updateUnit(int unitId, UnitOfMeasureDraft draft) {
    return _mutate(() async {
      final result = await _repository.updateUnit(id: unitId, draft: draft);
      switch (result) {
        case Ok<UnitOfMeasure>():
          _track('catalog.unit.updated', result.value);
          return true;
        case Error<UnitOfMeasure>():
          return false;
      }
    });
  }

  Future<bool> deleteUnit(UnitOfMeasure unit) {
    return _mutate(() async {
      final result = await _repository.deleteUnit(unit.id);
      switch (result) {
        case Ok<void>():
          _track('catalog.unit.deleted', unit);
          return true;
        case Error<void>():
          return false;
      }
    });
  }

  Future<bool> reorderUnits(List<int> orderedUnitIds) {
    return _mutate(() async {
      final result = await _repository.reorderUnits(orderedUnitIds);
      return result is Ok<void>;
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

  void _track(String name, UnitOfMeasure unit) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'unit_of_measure',
      entityId: unit.id,
      attributes: {
        'code': unit.code,
        'dimension': unit.dimension,
        'is_active': unit.isActive,
        'source': 'catalog',
      },
    );
  }
}
