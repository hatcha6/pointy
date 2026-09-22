import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;

import '../../core/storage/app_key_value_store.dart';
import '../models/device_settings.dart';
import '../models/price_checker_config.dart';
import '../models/printer_config.dart';

class DeviceSettingsStorageService {
  const DeviceSettingsStorageService();

  static const _deviceUsageModeKey = 'device_usage_mode';
  static const _themeModeKey = 'theme_mode';
  static const _defaultPrinterConfigKey = 'default_printer_config';
  static const _printerRoleConfigsKey = 'printer_role_configs';
  static const _kitchenStationConfigsKey = 'kitchen_station_configs';
  static const _priceCheckerConfigKey = 'price_checker_config';
  static const _dashboardCameraIdsKey = 'dashboard_camera_ids';
  static const _cameraWedgeEnabledKey = 'camera_wedge_enabled';
  static const _cameraWedgeDeviceIdKey = 'camera_wedge_device_id';

  Future<DeviceUsageMode?> loadDeviceUsageMode() async {
    final store = await AppKeyValueStore.instance();
    final encoded = await store.getString(_deviceUsageModeKey);
    if (encoded == null) {
      return null;
    }
    return deviceUsageModeFromJson(encoded);
  }

  Future<void> saveDeviceUsageMode(DeviceUsageMode usageMode) async {
    final store = await AppKeyValueStore.instance();
    await store.setString(
      _deviceUsageModeKey,
      deviceUsageModeToJson(usageMode),
    );
  }

  /// Whether a camera on this machine acts as a barcode scanner.
  ///
  /// Per device, like the printers and the dashboard cameras, and for the same
  /// reason: it describes the hardware in front of somebody, not the shop. One
  /// till has a camera on a stand over the counter and the office PC does not.
  ///
  /// `null` means nobody has chosen, which is NOT the same as off: the caller
  /// decides the default, and the default is off, because a camera that starts
  /// reading barcodes without being asked is a surprise.
  Future<bool?> loadCameraWedgeEnabled() async {
    final store = await AppKeyValueStore.instance();
    return switch (await store.getString(_cameraWedgeEnabledKey)) {
      'true' => true,
      'false' => false,
      _ => null,
    };
  }

  Future<void> saveCameraWedgeEnabled(bool enabled) async {
    final store = await AppKeyValueStore.instance();
    await store.setString(_cameraWedgeEnabledKey, enabled ? 'true' : 'false');
  }

  /// Which camera on this machine is the one over the counter.
  ///
  /// A till often has two — a built-in webcam facing the cashier and the one
  /// on a stand facing the counter — and reading barcodes off the wrong one
  /// is the whole feature failing. Blank means "whichever is first", which is
  /// right for the common case of exactly one.
  Future<String?> loadCameraWedgeDeviceId() async {
    final store = await AppKeyValueStore.instance();
    final value = await store.getString(_cameraWedgeDeviceIdKey);
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> saveCameraWedgeDeviceId(String? deviceId) async {
    final store = await AppKeyValueStore.instance();
    if (deviceId == null || deviceId.isEmpty) {
      await store.remove(_cameraWedgeDeviceIdKey);
      return;
    }
    await store.setString(_cameraWedgeDeviceIdKey, deviceId);
  }

  /// The light/dark/system preference for this device. `null` when the user has
  /// never chosen, letting callers fall back to their own default.
  Future<ThemeMode?> loadThemeMode() async {
    final store = await AppKeyValueStore.instance();
    return switch (await store.getString(_themeModeKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => null,
    };
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    final store = await AppKeyValueStore.instance();
    await store.setString(_themeModeKey, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }

  /// Which cameras this device shows on its dashboard.
  ///
  /// Three states, and the difference matters: `null` means nobody has chosen,
  /// so the dashboard picks sensible ones itself; an empty list means somebody
  /// chose *none* and the band stays hidden; a list is exactly what to show.
  ///
  /// Per device, like the printer and theme settings, because which cameras you
  /// want in front of you depends on which machine you are standing at — the
  /// office PC wants the till, the till wants the back door.
  Future<List<int>?> loadDashboardCameraIds() async {
    final store = await AppKeyValueStore.instance();
    final encoded = await store.getString(_dashboardCameraIdsKey);
    if (encoded == null) {
      return null;
    }
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) {
        return null;
      }
      return [
        for (final value in decoded)
          if (value is num) value.toInt(),
      ];
    } on FormatException {
      return null;
    }
  }

  Future<void> saveDashboardCameraIds(List<int> cameraIds) async {
    final store = await AppKeyValueStore.instance();
    await store.setString(_dashboardCameraIdsKey, jsonEncode(cameraIds));
  }

  /// Forgets the choice, putting the dashboard back on automatic.
  Future<void> clearDashboardCameraIds() async {
    final store = await AppKeyValueStore.instance();
    await store.remove(_dashboardCameraIdsKey);
  }

  /// The per-device price-checker (kiosk) configuration. Returns an empty
  /// config when this device has never been set up as a price checker.
  Future<PriceCheckerConfig> loadPriceCheckerConfig() async {
    final store = await AppKeyValueStore.instance();
    return PriceCheckerConfig.decode(
      await store.getString(_priceCheckerConfigKey),
    );
  }

  Future<void> savePriceCheckerConfig(PriceCheckerConfig config) async {
    final store = await AppKeyValueStore.instance();
    await store.setString(_priceCheckerConfigKey, config.encode());
  }

  Future<PrinterConfig?> loadDefaultPrinterConfig() async {
    return loadPrinterConfigForRole(PrinterRole.posReceipt);
  }

  Future<void> saveDefaultPrinterConfig(PrinterConfig config) async {
    await savePrinterConfigForRole(PrinterRole.posReceipt, config);
  }

  Future<PrinterConfig?> loadPrinterConfigForRole(PrinterRole role) async {
    final store = await AppKeyValueStore.instance();
    final roleConfigs = _decodeRoleConfigs(
      await store.getString(_printerRoleConfigsKey),
    );
    final encodedRoleConfig = roleConfigs[printerRoleToJson(role)];
    if (encodedRoleConfig is Map<String, Object?>) {
      return PrinterConfig.fromJson(encodedRoleConfig);
    }

    if (role != PrinterRole.posReceipt) {
      return null;
    }

    final encoded = await store.getString(_defaultPrinterConfigKey);
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
    final store = await AppKeyValueStore.instance();
    final roleConfigs = _decodeRoleConfigs(
      await store.getString(_printerRoleConfigsKey),
    );
    roleConfigs[printerRoleToJson(role)] = config.toJson();
    await store.setString(_printerRoleConfigsKey, jsonEncode(roleConfigs));
    if (role != PrinterRole.posReceipt) {
      return;
    }
    await store.setString(
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
    final store = await AppKeyValueStore.instance();
    final decoded = _decodeRoleConfigs(
      await store.getString(_kitchenStationConfigsKey),
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
    final store = await AppKeyValueStore.instance();
    final stationConfigs = _decodeRoleConfigs(
      await store.getString(_kitchenStationConfigsKey),
    );
    stationConfigs['$stationId'] = config.toJson();
    await store.setString(
      _kitchenStationConfigsKey,
      jsonEncode(stationConfigs),
    );
  }

  Future<void> removeKitchenStationConfig(int stationId) async {
    final store = await AppKeyValueStore.instance();
    final stationConfigs = _decodeRoleConfigs(
      await store.getString(_kitchenStationConfigsKey),
    );
    if (stationConfigs.remove('$stationId') == null) {
      return;
    }
    await store.setString(
      _kitchenStationConfigsKey,
      jsonEncode(stationConfigs),
    );
  }
}
