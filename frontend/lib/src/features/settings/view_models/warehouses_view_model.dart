import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/warehouse.dart';
import '../../../data/repositories/warehouse_repository.dart';

class WarehousesViewModel extends ChangeNotifier {
  WarehousesViewModel(this._repository);

  final WarehouseRepository _repository;

  List<Warehouse> _warehouses = const [];
  RegisterProfile? _profile;
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;

  /// Everything except the transit location. Goods on the road are a state the
  /// transfer document puts stock into, not a room anyone opens, counts or
  /// sells from — showing it in the shop's list of places would be showing a
  /// room that does not exist.
  List<Warehouse> get warehouses =>
      _warehouses.where((warehouse) => warehouse.sellsFrom).toList();

  /// Included so the transfer screens can name it, but never listed as a place.
  Warehouse? get transit {
    for (final warehouse in _warehouses) {
      if (!warehouse.sellsFrom) {
        return warehouse;
      }
    }
    return null;
  }

  Warehouse? get defaultWarehouse {
    for (final warehouse in warehouses) {
      if (warehouse.isDefault) {
        return warehouse;
      }
    }
    return warehouses.isEmpty ? null : warehouses.first;
  }

  /// True while the shop has never opened a second place — the state almost
  /// every shop is in, and the one the empty state speaks to.
  bool get hasOnlyOnePlace => warehouses.length <= 1;

  RegisterProfile? get registerProfile => _profile;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadWarehouses();
    switch (result) {
      case Ok<List<Warehouse>>():
        _warehouses = result.value;
      case Error<List<Warehouse>>():
        _hasLoadError = true;
    }

    // Best effort: a till that cannot read its own profile still sells, so a
    // failure here must not make the page look broken.
    final profile = await _repository.loadMyRegisterProfile();
    if (profile case Ok<RegisterProfile>()) {
      _profile = profile.value;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<String?> save(Warehouse warehouse) async {
    _isMutating = true;
    notifyListeners();
    final result = warehouse.id == 0
        ? await _repository.createWarehouse(warehouse)
        : await _repository.updateWarehouse(warehouse);
    _isMutating = false;
    switch (result) {
      case Ok<Warehouse>():
        await load();
        return null;
      case Error<Warehouse>():
        notifyListeners();
        return _messageFrom(result);
    }
  }

  Future<String?> delete(Warehouse warehouse) async {
    _isMutating = true;
    notifyListeners();
    final result = await _repository.deleteWarehouse(warehouse.id);
    _isMutating = false;
    switch (result) {
      case Ok<void>():
        await load();
        return null;
      case Error<void>():
        notifyListeners();
        return _messageFrom(result);
    }
  }

  Future<String?> assignThisTill(int warehouseId) async {
    _isMutating = true;
    notifyListeners();
    final result = await _repository.assignMyRegisterWarehouse(
      warehouseId: warehouseId,
    );
    _isMutating = false;
    switch (result) {
      case Ok<RegisterProfile>():
        _profile = result.value;
        notifyListeners();
        return null;
      case Error<RegisterProfile>():
        notifyListeners();
        return _messageFrom(result);
    }
  }

  /// The server's own sentence where there is one. It knows why a place cannot
  /// be deleted and we do not, so repeating its reason beats inventing a
  /// vaguer one.
  String? _messageFrom(Object result) {
    final failure = result is Error ? result.exception : null;
    final text = failure?.toString() ?? '';
    return text.isEmpty ? null : text;
  }
}
