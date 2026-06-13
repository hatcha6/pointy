import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/prep_station.dart';
import '../../../data/models/product_category.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/prep_station_repository.dart';

class PrepStationsViewModel extends ChangeNotifier {
  PrepStationsViewModel(
    this._repository,
    this._catalogRepository, {
    AnalyticsEngine? analyticsEngine,
  }) : _analyticsEngine = analyticsEngine;

  final PrepStationRepository _repository;
  final CatalogRepository _catalogRepository;
  final AnalyticsEngine? _analyticsEngine;

  List<PrepStation> _stations = const [];
  List<ProductCategory> _categories = const [];
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;
  bool _hasMutationError = false;

  List<PrepStation> get stations => _stations;
  List<ProductCategory> get categories => _categories;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;
  bool get hasMutationError => _hasMutationError;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final stationsResult = await _repository.loadStations();
    switch (stationsResult) {
      case Ok<List<PrepStation>>():
        _stations = stationsResult.value;
      case Error<List<PrepStation>>():
        _hasLoadError = true;
    }
    await _loadCategories();

    _isLoading = false;
    notifyListeners();
  }

  Future<void> _loadCategories() async {
    final categories = <ProductCategory>[];
    var page = 1;
    var hasMore = true;
    while (hasMore) {
      final result = await _catalogRepository.loadProductCategories(page: page);
      switch (result) {
        case Ok<ProductCategoryPage>():
          categories.addAll(result.value.categories);
          hasMore = result.value.hasMore;
          page += 1;
        case Error<ProductCategoryPage>():
          hasMore = false;
      }
    }
    _categories = categories;
  }

  Future<bool> createStation(PrepStationDraft draft) async {
    return _mutate(() async {
      final result = await _repository.createStation(draft);
      switch (result) {
        case Ok<PrepStation>():
          _trackEvent('settings.prep_station.created', result.value);
          return true;
        case Error<PrepStation>():
          _hasMutationError = true;
          return false;
      }
    });
  }

  Future<bool> updateStation(
    int stationId,
    Map<String, Object?> changes,
  ) async {
    return _mutate(() async {
      final result = await _repository.updateStation(stationId, changes);
      switch (result) {
        case Ok<PrepStation>():
          _trackEvent('settings.prep_station.updated', result.value);
          return true;
        case Error<PrepStation>():
          _hasMutationError = true;
          return false;
      }
    });
  }

  Future<bool> deleteStation(PrepStation station) async {
    return _mutate(() async {
      final result = await _repository.deleteStation(station.id);
      switch (result) {
        case Ok<void>():
          _trackEvent('settings.prep_station.deleted', station);
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
    await load();
    return outcome;
  }

  void _trackEvent(String name, PrepStation station) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'prep_station',
      entityId: station.id,
      attributes: {
        'is_default': station.isDefault,
        'category_count': station.categoryIds.length,
        'source': 'shop_settings',
      },
    );
  }
}
