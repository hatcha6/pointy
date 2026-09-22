import '../../core/result.dart';
import '../models/device_settings.dart';
import '../services/device_settings_storage_service.dart';

class DeviceSettingsRepository {
  const DeviceSettingsRepository({
    DeviceSettingsStorageService storageService =
        const DeviceSettingsStorageService(),
  }) : _storageService = storageService;

  final DeviceSettingsStorageService _storageService;

  Future<Result<DeviceSettings>> loadSettings() async {
    return Result.guard(() async {
      final usageMode = await _storageService.loadDeviceUsageMode();
      final cameraWedgeEnabled =
          await _storageService.loadCameraWedgeEnabled();
      return DeviceSettings(
        usageMode: usageMode ?? DeviceSettings.defaults().usageMode,
        cameraWedgeEnabled:
            cameraWedgeEnabled ?? DeviceSettings.defaults().cameraWedgeEnabled,
        cameraWedgeDeviceId: await _storageService.loadCameraWedgeDeviceId(),
      );
    });
  }

  Future<Result<DeviceUsageMode>> loadUsageMode() async {
    return Result.guard(() async {
      return await _storageService.loadDeviceUsageMode() ??
          DeviceSettings.defaults().usageMode;
    });
  }

  Future<Result<void>> saveUsageMode(DeviceUsageMode usageMode) async {
    return Result.guard(() => _storageService.saveDeviceUsageMode(usageMode));
  }

  /// Whether this machine's camera acts as a barcode scanner. Off until a shop
  /// says otherwise — a camera that starts reading on its own is a surprise.
  Future<Result<bool>> loadCameraWedgeEnabled() async {
    return Result.guard(
      () async => await _storageService.loadCameraWedgeEnabled() ?? false,
    );
  }

  Future<Result<void>> saveCameraWedgeEnabled(bool enabled) async {
    return Result.guard(
      () => _storageService.saveCameraWedgeEnabled(enabled),
    );
  }

  Future<Result<String?>> loadCameraWedgeDeviceId() async {
    return Result.guard(() => _storageService.loadCameraWedgeDeviceId());
  }

  Future<Result<void>> saveCameraWedgeDeviceId(String? deviceId) async {
    return Result.guard(
      () => _storageService.saveCameraWedgeDeviceId(deviceId),
    );
  }
}
