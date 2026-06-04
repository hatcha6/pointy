import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/device_settings.dart';
import '../models/printer_config.dart';

class DeviceSettingsStorageService {
  const DeviceSettingsStorageService();

  static const _deviceUsageModeKey = 'device_usage_mode';
  static const _defaultPrinterConfigKey = 'default_printer_config';
  static const _printerRoleConfigsKey = 'printer_role_configs';

  Future<DeviceUsageMode?> loadDeviceUsageMode() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_deviceUsageModeKey);
    if (encoded == null) {
      return null;
    }
    return deviceUsageModeFromJson(encoded);
  }

  Future<void> saveDeviceUsageMode(DeviceUsageMode usageMode) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _deviceUsageModeKey,
      deviceUsageModeToJson(usageMode),
    );
  }

  Future<PrinterConfig?> loadDefaultPrinterConfig() async {
    return loadPrinterConfigForRole(PrinterRole.posReceipt);
  }

  Future<void> saveDefaultPrinterConfig(PrinterConfig config) async {
    await savePrinterConfigForRole(PrinterRole.posReceipt, config);
  }

  Future<PrinterConfig?> loadPrinterConfigForRole(PrinterRole role) async {
    final preferences = await SharedPreferences.getInstance();
    final roleConfigs = _decodeRoleConfigs(
      preferences.getString(_printerRoleConfigsKey),
    );
    final encodedRoleConfig = roleConfigs[printerRoleToJson(role)];
    if (encodedRoleConfig is Map<String, Object?>) {
      return PrinterConfig.fromJson(encodedRoleConfig);
    }

    if (role != PrinterRole.posReceipt) {
      return null;
    }

    final encoded = preferences.getString(_defaultPrinterConfigKey);
    if (encoded == null) {
      return null;
    }

    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, Object?>) {
      return null;
    }

    return PrinterConfig.fromJson(decoded);
  }

  Future<void> savePrinterConfigForRole(
    PrinterRole role,
    PrinterConfig config,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final roleConfigs = _decodeRoleConfigs(
      preferences.getString(_printerRoleConfigsKey),
    );
    roleConfigs[printerRoleToJson(role)] = config.toJson();
    await preferences.setString(
      _printerRoleConfigsKey,
      jsonEncode(roleConfigs),
    );
    if (role != PrinterRole.posReceipt) {
      return;
    }
    await preferences.setString(
      _defaultPrinterConfigKey,
      jsonEncode(config.toJson()),
    );
  }

  Map<String, Object?> _decodeRoleConfigs(String? encoded) {
    if (encoded == null) {
      return <String, Object?>{};
    }
    final decoded = jsonDecode(encoded);
    if (decoded is Map<String, Object?>) {
      return Map<String, Object?>.of(decoded);
    }
    return <String, Object?>{};
  }
}
