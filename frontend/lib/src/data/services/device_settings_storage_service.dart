import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device_settings.dart';
import '../models/printer_config.dart';

class DeviceSettingsStorageService {
  const DeviceSettingsStorageService();

  static const _deviceUsageModeKey = 'device_usage_mode';
  static const _themeModeKey = 'theme_mode';
  static const _defaultPrinterConfigKey = 'default_printer_config';
  static const _printerRoleConfigsKey = 'printer_role_configs';
  static const _kitchenStationConfigsKey = 'kitchen_station_configs';

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

  /// The light/dark/system preference for this device. `null` when the user has
  /// never chosen, letting callers fall back to their own default.
  Future<ThemeMode?> loadThemeMode() async {
    final preferences = await SharedPreferences.getInstance();
    return switch (preferences.getString(_themeModeKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => null,
    };
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_themeModeKey, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
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

  /// The kitchen printer(s) this device is responsible for, keyed by prep
  /// station id. A device "serves" a station only when it has a saved config
  /// here; otherwise kitchen chits for that station stay queued for another
  /// device. Stored as `{ "<stationId>": <PrinterConfig json> }`.
  Future<Map<int, PrinterConfig>> loadKitchenStationConfigs() async {
    final preferences = await SharedPreferences.getInstance();
    final decoded = _decodeRoleConfigs(
      preferences.getString(_kitchenStationConfigsKey),
    );
    final configs = <int, PrinterConfig>{};
    decoded.forEach((key, value) {
      final stationId = int.tryParse(key);
      if (stationId != null && value is Map<String, Object?>) {
        configs[stationId] = PrinterConfig.fromJson(value);
      }
    });
    return configs;
  }

  Future<PrinterConfig?> loadKitchenStationConfig(int stationId) async {
    final configs = await loadKitchenStationConfigs();
    return configs[stationId];
  }

  Future<void> saveKitchenStationConfig(
    int stationId,
    PrinterConfig config,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final stationConfigs = _decodeRoleConfigs(
      preferences.getString(_kitchenStationConfigsKey),
    );
    stationConfigs['$stationId'] = config.toJson();
    await preferences.setString(
      _kitchenStationConfigsKey,
      jsonEncode(stationConfigs),
    );
  }

  Future<void> removeKitchenStationConfig(int stationId) async {
    final preferences = await SharedPreferences.getInstance();
    final stationConfigs = _decodeRoleConfigs(
      preferences.getString(_kitchenStationConfigsKey),
    );
    if (stationConfigs.remove('$stationId') == null) {
      return;
    }
    await preferences.setString(
      _kitchenStationConfigsKey,
      jsonEncode(stationConfigs),
    );
  }
}
