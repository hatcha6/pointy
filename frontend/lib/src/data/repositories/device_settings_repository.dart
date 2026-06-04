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
      return DeviceSettings(
        usageMode: usageMode ?? DeviceSettings.defaults().usageMode,
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
}
