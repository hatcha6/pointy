import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/shop_settings_repository.dart';

class ShopSettingsViewModel extends ChangeNotifier {
  ShopSettingsViewModel(this._repository) {
    loadSettings();
  }

  final ShopSettingsRepository _repository;

  ShopSettings? _settings;
  bool _isLoading = false;
  bool _isSaving = false;
  bool _hasLoadError = false;
  bool _hasSaveError = false;

  ShopSettings? get settings => _settings;
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  bool get hasLoadError => _hasLoadError;
  bool get hasSaveError => _hasSaveError;

  Future<void> loadSettings() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadSettings();
    switch (result) {
      case Ok<ShopSettings>():
        _settings = result.value;
      case Error<ShopSettings>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> updateSettings(ShopSettingsDraft draft) async {
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final result = await _repository.updateSettings(draft);
    _isSaving = false;
    switch (result) {
      case Ok<ShopSettings>():
        _settings = result.value;
        notifyListeners();
        return true;
      case Error<ShopSettings>():
        _hasSaveError = true;
        notifyListeners();
        return false;
    }
  }
}
