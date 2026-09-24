import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/storage/app_key_value_store.dart';
import '../../core/storage/key_value_store.dart';
import '../models/device_printers.dart';
import '../models/printer_config.dart';

/// Where this device keeps its printer list.
///
/// Printers are per device, like the theme and the counter camera: they
/// describe the hardware plugged into this machine, not the shop.
///
/// Builds before the printer list kept one receipt printer and one printer
/// per kitchen station. Those settings are migrated on read — nothing is
/// written until the list is first saved — and every save writes them back
/// as a mirror, so an older build (a rolled-back update, a till not yet
/// updated) still prints receipts and chits where this one does.
class DevicePrintersStorage {
  const DevicePrintersStorage();

  static const printersKey = 'device_printers';
  static const legacyDefaultPrinterKey = 'default_printer_config';
  static const legacyRoleConfigsKey = 'printer_role_configs';
  static const legacyKitchenStationsKey = 'kitchen_station_configs';
  static const _legacyReceiptRole = 'pos_receipt';

  Future<DevicePrinters> load() async {
    final store = await AppKeyValueStore.instance();
    final stored = _decodeMap(await store.getString(printersKey));
    if (stored != null) {
      return DevicePrinters.fromJson(stored);
    }
    // Never saved — or saved and since damaged, in which case the mirror is
    // the last good copy of the printers that matter most.
    return migrateLegacyPrinters(
      receiptPrinter: await _loadLegacyReceiptPrinter(store),
      kitchenStations: await _loadLegacyKitchenStations(store),
    );
  }

  Future<void> save(DevicePrinters printers) async {
    final store = await AppKeyValueStore.instance();
    await store.setString(printersKey, jsonEncode(printers.toJson()));
    try {
      await _writeLegacyMirror(store, printers);
    } on Object catch (error) {
      // The list itself is saved; the mirror only serves older builds.
      debugPrint('Printer settings mirror not written: $error');
    }
  }

  Future<PrinterConfig?> _loadLegacyReceiptPrinter(KeyValueStore store) async {
    final roleConfigs = _decodeMap(await store.getString(legacyRoleConfigsKey));
    final roleConfig = roleConfigs?[_legacyReceiptRole];
    if (roleConfig is Map<String, Object?>) {
      return PrinterConfig.fromJson(roleConfig);
    }
    final defaultConfig = _decodeMap(
      await store.getString(legacyDefaultPrinterKey),
    );
    return defaultConfig == null ? null : PrinterConfig.fromJson(defaultConfig);
  }

  Future<Map<int, PrinterConfig>> _loadLegacyKitchenStations(
    KeyValueStore store,
  ) async {
    final decoded = _decodeMap(await store.getString(legacyKitchenStationsKey));
    return {
      if (decoded != null)
        for (final MapEntry(:key, :value) in decoded.entries)
          if ((int.tryParse(key), value) case (
            final int stationId,
            final Map<String, Object?> config,
          ))
            stationId: PrinterConfig.fromJson(config),
    };
  }

  Future<void> _writeLegacyMirror(
    KeyValueStore store,
    DevicePrinters printers,
  ) async {
    final receipt = printers.holderOf(PrinterRole.posReceipt)?.config;
    final roleConfigs =
        _decodeMap(await store.getString(legacyRoleConfigsKey)) ??
        <String, Object?>{};
    if (receipt == null) {
      roleConfigs.remove(_legacyReceiptRole);
      await store.remove(legacyDefaultPrinterKey);
    } else {
      roleConfigs[_legacyReceiptRole] = receipt.toJson();
      await store.setString(
        legacyDefaultPrinterKey,
        jsonEncode(receipt.toJson()),
      );
    }
    await store.setString(legacyRoleConfigsKey, jsonEncode(roleConfigs));
    await store.setString(
      legacyKitchenStationsKey,
      jsonEncode({
        for (final MapEntry(:key, :value)
            in printers.kitchenStationConfigs.entries)
          '$key': value.toJson(),
      }),
    );
  }

  static Map<String, Object?>? _decodeMap(String? encoded) {
    if (encoded == null) {
      return null;
    }
    try {
      final decoded = jsonDecode(encoded);
      return decoded is Map<String, Object?>
          ? Map<String, Object?>.of(decoded)
          : null;
    } on FormatException {
      return null;
    }
  }
}

/// The printer list an older build's settings describe.
///
/// Its one printer printed receipts *and* barcode labels, so it keeps both
/// jobs — nothing that printed before stops printing. It never held the
/// documents job: reports opened the print dialog, and purchase orders
/// already fall back to the receipt printer. Each kitchen station had its
/// own printer config; a station whose config is the receipt printer's to
/// the byte joins that printer rather than listing the device twice.
///
/// Ids are fixed, so migrating twice (a read before the first save, then
/// another) names the same printers the same way.
@visibleForTesting
DevicePrinters migrateLegacyPrinters({
  PrinterConfig? receiptPrinter,
  Map<int, PrinterConfig> kitchenStations = const {},
}) {
  var printers = DevicePrinters.empty;
  if (receiptPrinter != null && receiptPrinter.endpoint.isConfigured) {
    printers = printers.upsert(
      DevicePrinter(
        id: 'legacy-receipt',
        config: receiptPrinter,
        roles: const {PrinterRole.posReceipt, PrinterRole.barcodeLabels},
      ),
    );
  }
  final stationIds = kitchenStations.keys.toList()..sort();
  for (final stationId in stationIds) {
    final config = kitchenStations[stationId]!;
    // A chit on a driver printer never printed: the checkout only claims
    // kitchen jobs for thermal printers. There is nothing here to keep.
    if (!config.endpoint.isConfigured || !config.endpoint.canServeKitchen) {
      continue;
    }
    final endpointJson = jsonEncode(config.endpoint.toJson());
    final sameDevice = printers.printers
        .where(
          (printer) => jsonEncode(printer.endpoint.toJson()) == endpointJson,
        )
        .firstOrNull;
    printers = printers.upsert(
      sameDevice == null
          ? DevicePrinter(
              id: 'legacy-kitchen-$stationId',
              config: config,
              kitchenStationIds: {stationId},
            )
          : sameDevice.copyWith(
              kitchenStationIds: {...sameDevice.kitchenStationIds, stationId},
            ),
    );
  }
  return printers;
}
