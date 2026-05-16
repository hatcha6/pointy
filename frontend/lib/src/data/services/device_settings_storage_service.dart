import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/printer_config.dart';

class DeviceSettingsStorageService {
  const DeviceSettingsStorageService();

  static const _defaultPrinterConfigKey = 'default_printer_config';

  Future<PrinterConfig?> loadDefaultPrinterConfig() async {
    final preferences = await SharedPreferences.getInstance();
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

  Future<void> saveDefaultPrinterConfig(PrinterConfig config) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _defaultPrinterConfigKey,
      jsonEncode(config.toJson()),
    );
  }
}
