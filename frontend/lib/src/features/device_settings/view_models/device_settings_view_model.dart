import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/device_settings.dart';
import '../../../data/repositories/device_settings_repository.dart';

class DeviceSettingsViewModel extends ChangeNotifier {
  DeviceSettingsViewModel(this._repository) {
    loadSettings();
  }

  final DeviceSettingsRepository _repository;

  DeviceSettings _settings = DeviceSettings.defaults();
  bool _isLoading = false;
  bool _isSaving = false;
  bool _hasLoadError = false;
  bool _hasSaveError = false;

  DeviceSettings get settings => _settings;
  DeviceUsageMode get usageMode => _settings.usageMode;
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
      case Ok<DeviceSettings>(value: final settings):
        _settings = settings;
      case Error<DeviceSettings>():
        _settings = DeviceSettings.defaults();
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> updateUsageMode(DeviceUsageMode usageMode) async {
    if (_settings.usageMode == usageMode || _isSaving) {
      return;
    }

    final previousSettings = _settings;
    _settings = _settings.copyWith(usageMode: usageMode);
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final result = await _repository.saveUsageMode(usageMode);
    if (result is Error<void>) {
      _settings = previousSettings;
      _hasSaveError = true;
    }

    _isSaving = false;
    notifyListeners();
  }
}
