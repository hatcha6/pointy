import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/customer_asset.dart';
import '../../../data/repositories/operations_repository.dart';

/// One item's whole story: what it is, who owns it, who owned it before, and
/// every job the shop has done to it.
class AssetDetailsViewModel extends ChangeNotifier {
  AssetDetailsViewModel(this._repository, {required this.assetId});

  final OperationsRepository _repository;
  final int assetId;

  CustomerAssetDetail? _detail;
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;
  String _mutationError = '';

  CustomerAssetDetail? get detail => _detail;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;
  String get mutationError => _mutationError;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadCustomerAsset(assetId);
    switch (result) {
      case Ok<CustomerAssetDetail>():
        _detail = result.value;
      case Error<CustomerAssetDetail>():
        _hasLoadError = true;
    }
    _isLoading = false;
    notifyListeners();
  }

  /// Hands the item to a new owner. The service history stays with the item —
  /// that is the whole reason the registry is keyed on the thing, not the
  /// person — so this reloads rather than clearing.
  Future<bool> transfer({required int customerId, String note = ''}) async {
    _isMutating = true;
    _mutationError = '';
    notifyListeners();

    final result = await _repository.transferCustomerAsset(
      assetId,
      customer: customerId,
      note: note,
    );
    var succeeded = false;
    switch (result) {
      case Ok<CustomerAsset>():
        succeeded = true;
      case Error<CustomerAsset>():
        _mutationError = result.exception.toString();
    }
    _isMutating = false;
    notifyListeners();
    if (succeeded) {
      await load();
    }
    return succeeded;
  }
}
