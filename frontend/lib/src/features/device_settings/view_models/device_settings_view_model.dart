import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/device_settings.dart';
import '../../../data/repositories/device_settings_repository.dart';
import '../../../shared/barcode/camera_wedge/camera_wedge_controller.dart';
import '../../../shared/barcode/camera_wedge/camera_wedge_source.dart' show CameraWedgeBackend, CameraWedgeDevice;

class DeviceSettingsViewModel extends ChangeNotifier {
  DeviceSettingsViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine {
    loadSettings();
  }

  final DeviceSettingsRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  DeviceSettings _settings = DeviceSettings.defaults();
  bool _isLoading = false;
  bool _isSaving = false;
  bool _hasLoadError = false;
  bool _hasSaveError = false;

  DeviceSettings get settings => _settings;
  DeviceUsageMode get usageMode => _settings.usageMode;

  /// Whether this machine's camera acts as a scanner, and whether it CAN.
  /// A platform with no camera source hides the setting rather than offering
  /// a switch that does nothing.
  bool get cameraWedgeEnabled => _settings.cameraWedgeEnabled;
  bool get cameraWedgeSupported =>
      CameraWedgeController.backend != CameraWedgeBackend.none;

  /// True where this platform's wedge reads 2-D codes only, so the setting can
  /// say so instead of letting a shop discover it on a bag of rice.
  bool get cameraWedgeReadsTwoDimensionalOnly =>
      CameraWedgeController.readsTwoDimensionalOnly;

  /// Cameras this machine can see. Empty until [loadCameraWedgeDevices] has
  /// run, and on platforms whose backend cannot enumerate (mobile_scanner
  /// addresses cameras by facing, not by id).
  List<CameraWedgeDevice> get cameraWedgeDevices => _cameraWedgeDevices;
  List<CameraWedgeDevice> _cameraWedgeDevices = const [];

  /// The chosen camera, or null for "whichever is first".
  String? get cameraWedgeDeviceId => _settings.cameraWedgeDeviceId;

  /// Ask the platform which cameras exist. Cheap, and re-runnable: a shop that
  /// plugs one in while this screen is open presses the same button again.
  Future<void> loadCameraWedgeDevices() async {
    if (!cameraWedgeSupported) return;
    final probe = CameraWedgeController();
    try {
      _cameraWedgeDevices = await probe.devices();
    } catch (_) {
      _cameraWedgeDevices = const [];
    } finally {
      await probe.dispose();
    }
    notifyListeners();
  }

  /// Point the wedge at a different camera. A till often has two — a webcam
  /// facing the cashier and the one on a stand facing the counter — and
  /// reading off the wrong one is the whole feature failing.
  Future<void> updateCameraWedgeDevice(
    String? deviceId, {
    Future<void> Function()? onChanged,
  }) async {
    if (_settings.cameraWedgeDeviceId == deviceId || _isSaving) return;
    final previousSettings = _settings;
    _settings = DeviceSettings(
      usageMode: _settings.usageMode,
      cameraWedgeEnabled: _settings.cameraWedgeEnabled,
      cameraWedgeDeviceId: deviceId,
    );
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final result = await _repository.saveCameraWedgeDeviceId(deviceId);
    if (result is Error<void>) {
      _settings = previousSettings;
      _hasSaveError = true;
    } else {
      await onChanged?.call();
    }
    _isSaving = false;
    notifyListeners();
  }
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

  /// Turn the counter camera on or off for this machine.
  ///
  /// [onChanged] lets the app start or stop the camera immediately, so a shop
  /// that switches it on can use it without restarting the till.
  Future<void> updateCameraWedgeEnabled(
    bool enabled, {
    Future<void> Function()? onChanged,
  }) async {
    if (_settings.cameraWedgeEnabled == enabled || _isSaving) {
      return;
    }
    final previousSettings = _settings;
    _settings = _settings.copyWith(cameraWedgeEnabled: enabled);
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final result = await _repository.saveCameraWedgeEnabled(enabled);
    if (result is Error<void>) {
      _settings = previousSettings;
      _hasSaveError = true;
    } else {
      await onChanged?.call();
    }
    _isSaving = false;
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
    } else {
      _trackUsageModeChanged(
        previousMode: previousSettings.usageMode,
        nextMode: usageMode,
      );
    }

    _isSaving = false;
    notifyListeners();
  }

  void _trackUsageModeChanged({
    required DeviceUsageMode previousMode,
    required DeviceUsageMode nextMode,
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'settings.device.usage_mode_changed',
      entityType: 'device_settings',
      attributes: {
        'previous_usage_mode': previousMode.name,
        'new_usage_mode': nextMode.name,
        'source': 'device_settings',
      },
    );
  }
}
