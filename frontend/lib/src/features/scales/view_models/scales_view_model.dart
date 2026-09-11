import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/analytics_export.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_page.dart';
import '../../../data/models/scale.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/scales_repository.dart';

/// Drives the scales screen: the shop's scales, their reachability, and the
/// push that makes them agree with the catalog.
class ScalesViewModel extends ChangeNotifier {
  ScalesViewModel(this._repository, this._catalogRepository);

  final ScalesRepository _repository;
  final CatalogRepository _catalogRepository;

  List<Scale> _scales = const [];
  List<ScaleDriverInfo> _drivers = const [];
  List<ScalePlu> _plus = const [];
  final Map<int, ScalePushJob> _lastPush = {};
  final Map<int, ScaleReachability> _reachability = {};
  bool _isLoading = false;
  bool _hasLoadError = false;
  int? _busyScaleId;
  String _errorMessage = '';

  List<Scale> get scales => _scales;
  List<ScaleDriverInfo> get drivers => _drivers;
  List<ScalePlu> get plus => _plus;
  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;
  int? get busyScaleId => _busyScaleId;
  String get errorMessage => _errorMessage;

  /// How many products are on the scales at all. A push of nothing is the most
  /// common first failure, and this is what the screen says instead.
  int get assignedCount => _plus.where((plu) => plu.isActive).length;

  ScalePushJob? lastPushFor(int scaleId) => _lastPush[scaleId];
  ScaleReachability? reachabilityFor(int scaleId) => _reachability[scaleId];

  ScaleDriverInfo? driverFor(String key) {
    for (final driver in _drivers) {
      if (driver.key == key) {
        return driver;
      }
    }
    return null;
  }

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final results = await Future.wait([
      _repository.loadScales(),
      _repository.loadDrivers(),
      _repository.loadPlus(),
    ]);
    switch (results[0]) {
      case Ok<List<Scale>>(:final value):
        _scales = value;
      case Error<List<Scale>>():
        _hasLoadError = true;
      default:
        break;
    }
    if (results[1] case Ok<List<ScaleDriverInfo>>(:final value)) {
      _drivers = value;
    }
    if (results[2] case Ok<List<ScalePlu>>(:final value)) {
      _plus = value;
    }
    _isLoading = false;
    notifyListeners();

    for (final scale in _scales) {
      unawaited(_loadLastPush(scale.id));
    }
  }

  Future<void> _loadLastPush(int scaleId) async {
    final result = await _repository.loadPushes(scaleId);
    if (result case Ok<List<ScalePushJob>>(
      :final value,
    ) when value.isNotEmpty) {
      _lastPush[scaleId] = value.first;
      notifyListeners();
    }
  }

  Future<bool> save({int? id, required Map<String, Object?> draft}) async {
    return _mutate(() async {
      final result = await _repository.saveScale(id: id, draft: draft);
      return result is Ok<Scale>;
    });
  }

  Future<bool> remove(int id) async {
    return _mutate(() async {
      final result = await _repository.deleteScale(id);
      return result is Ok<void>;
    });
  }

  Future<ScaleReachability?> check(int id) async {
    _busyScaleId = id;
    _errorMessage = '';
    notifyListeners();
    final result = await _repository.checkScale(id);
    _busyScaleId = null;
    switch (result) {
      case Ok<ScaleReachability>(:final value):
        _reachability[id] = value;
        notifyListeners();
        return value;
      case Error<ScaleReachability>(:final exception):
        _errorMessage = exception.toString();
        notifyListeners();
        return null;
    }
  }

  Future<ScalePushJob?> push(int id) async {
    _busyScaleId = id;
    _errorMessage = '';
    notifyListeners();
    final result = await _repository.pushScale(id);
    _busyScaleId = null;
    switch (result) {
      case Ok<ScalePushJob>(:final value):
        _lastPush[id] = value;
        notifyListeners();
        await load();
        return value;
      case Error<ScalePushJob>(:final exception):
        _errorMessage = exception.toString();
        notifyListeners();
        return null;
    }
  }

  /// The PLU file for a scale that is loaded by hand, ready to be saved.
  Future<AnalyticsExportFile?> exportFile(int id) async {
    _busyScaleId = id;
    _errorMessage = '';
    notifyListeners();
    final result = await _repository.exportPluFile(id);
    _busyScaleId = null;
    switch (result) {
      case Ok<(String, Uint8List)>(:final value):
        final (filename, bytes) = value;
        notifyListeners();
        return AnalyticsExportFile.inMemory(
          bytes: bytes,
          filename: filename,
          contentType: 'text/csv',
          sizeBytes: bytes.length,
        );
      case Error<(String, Uint8List)>(:final exception):
        // Most often: nothing is on the scales yet. A button that does nothing
        // at all is the one outcome the shop cannot act on.
        _errorMessage = exception.toString();
        notifyListeners();
        return null;
    }
  }

  /// Products a shop can put on a scale, matched by name, SKU or barcode.
  Future<List<ProductVariant>> searchVariants(String term) async {
    final trimmed = term.trim();
    if (trimmed.isEmpty) {
      return const <ProductVariant>[];
    }
    final assigned = {for (final plu in _plus) plu.variantId};
    final result = await _catalogRepository.loadProductVariants(
      query: ProductQuery(
        search: trimmed,
        availability: ProductAvailabilityFilter.active,
      ),
    );
    if (result case Ok<ProductVariantPage>(:final value)) {
      return [
        for (final variant in value.variants)
          if (!assigned.contains(variant.id)) variant,
      ];
    }
    return const <ProductVariant>[];
  }

  Future<bool> assignPlu(int variantId, {String labelName = ''}) async {
    return _mutate(() async {
      final result = await _repository.assignPlu(
        variantId: variantId,
        labelName: labelName,
      );
      return result is Ok<ScalePlu>;
    });
  }

  Future<bool> retirePlu(int id, {required bool isActive}) async {
    return _mutate(() async {
      final result = await _repository.updatePlu(
        id: id,
        changes: {'is_active': isActive},
      );
      return result is Ok<ScalePlu>;
    });
  }

  Future<bool> _mutate(Future<bool> Function() action) async {
    _errorMessage = '';
    notifyListeners();
    final ok = await action();
    if (ok) {
      await load();
    } else {
      notifyListeners();
    }
    return ok;
  }
}
