import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/customer_asset.dart';
import '../../../data/repositories/operations_repository.dart';

/// The kinds of item this shop takes in.
///
/// Shop-editable so a repairer of televisions, generators or bicycles is not
/// waiting on a code change to write down what came through the door.
class AssetTypesViewModel extends ChangeNotifier {
  AssetTypesViewModel(this._repository);

  final OperationsRepository _repository;

  List<CustomerAssetType> _types = const [];
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;
  String _mutationError = '';

  List<CustomerAssetType> get types => _types;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;
  String get mutationError => _mutationError;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    // Inactive types are included here deliberately: this is the screen where a
    // shop turns one back on, so hiding them would strand them.
    final result = await _repository.loadAssetTypes();
    switch (result) {
      case Ok<List<CustomerAssetType>>():
        _types = result.value;
      case Error<List<CustomerAssetType>>():
        _hasLoadError = true;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<bool> save(CustomerAssetType type) async {
    return _mutate(() => _repository.saveAssetType(type));
  }

  Future<bool> remove(int typeId) async {
    return _mutate(() => _repository.deleteAssetType(typeId));
  }

  Future<bool> _mutate(Future<Result<Object?>> Function() operation) async {
    _isMutating = true;
    _mutationError = '';
    notifyListeners();

    final result = await operation();
    var ok = false;
    switch (result) {
      case Ok():
        ok = true;
      case Error():
        _mutationError = result.exception.toString();
    }
    _isMutating = false;
    notifyListeners();
    if (ok) {
      await load();
    }
    return ok;
  }
}
