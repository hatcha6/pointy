import 'dart:convert';
import 'dart:math';

import 'printer_config.dart';

/// A job this device hands to exactly one of its printers.
///
/// A shop with two printers — receipts at the counter, stickers on the
/// shelf-stocking bench — used to have one printer setting per device and
/// flipped it back and forth. Each job now has its own printer.
///
/// The kitchen is deliberately not a role: it is one job per prep station
/// ([DevicePrinter.kitchenStationIds]), because a café's grill and bar chits
/// often print in different places.
enum PrinterRole {
  /// Sale receipts at the till and their reprints, payment receipts
  /// (سندات القبض والصرف) and the thermal end-of-shift report.
  posReceipt,

  /// Barcode stickers.
  barcodeLabels,

  /// Full-page documents: business reports, the A4 shift report, consignment
  /// papers and purchase orders. With nobody holding it, reports open the
  /// system print dialog and purchase orders print on the receipt printer —
  /// exactly what they did before printers had jobs.
  documents,
}

PrinterRole? printerRoleFromJson(Object? value) {
  return switch (value?.toString()) {
    'pos_receipt' || 'posReceipt' || 'receipts' => PrinterRole.posReceipt,
    'barcode_labels' ||
    'barcodeLabels' ||
    'labels' => PrinterRole.barcodeLabels,
    'documents' || 'a4' => PrinterRole.documents,
    _ => null,
  };
}

String printerRoleToJson(PrinterRole role) {
  return switch (role) {
    PrinterRole.posReceipt => 'pos_receipt',
    PrinterRole.barcodeLabels => 'barcode_labels',
    PrinterRole.documents => 'documents',
  };
}

/// No printer on this device holds [role].
class PrinterRoleUnassigned implements Exception {
  const PrinterRoleUnassigned(this.role);

  final PrinterRole role;

  @override
  String toString() =>
      'no printer on this device holds ${printerRoleToJson(role)}';
}

/// What a printer can physically do, whatever it has been asked to.
extension PrinterEndpointJobs on PrinterEndpoint {
  /// Receipts and labels print on anything: raw thermal printers speak
  /// ESC/POS or a label language, driver printers take a PDF. Documents are
  /// PDFs, so only a printer driven through its own driver can take them.
  bool canServe(PrinterRole role) {
    return switch (role) {
      PrinterRole.posReceipt || PrinterRole.barcodeLabels => true,
      PrinterRole.documents => usesDocumentInvoice,
    };
  }

  /// Kitchen chits are claimed from the backend queue and written raw, which
  /// only a thermal printer can take.
  bool get canServeKitchen => usesThermalReceipt;
}

/// One printer connected to this device, and the jobs it does.
class DevicePrinter {
  const DevicePrinter({
    required this.id,
    required this.config,
    this.label = '',
    this.roles = const {},
    this.kitchenStationIds = const {},
  });

  /// Device-local identity. Survives renaming the printer and pointing it at
  /// a different device, so a job never follows a name.
  final String id;

  /// What the shop calls this printer ("الكاشير", "الملصقات"). Empty means
  /// "call it by the device's own name".
  final String label;
  final PrinterConfig config;
  final Set<PrinterRole> roles;

  /// The prep stations whose chits print here.
  final Set<int> kitchenStationIds;

  PrinterEndpoint get endpoint => config.endpoint;

  bool holds(PrinterRole role) => roles.contains(role);

  bool servesKitchenStation(int stationId) =>
      kitchenStationIds.contains(stationId);

  bool get hasJobs => roles.isNotEmpty || kitchenStationIds.isNotEmpty;

  /// Drops the jobs this printer cannot physically do, so a printer pointed
  /// at a different device never keeps a job it would silently fail.
  DevicePrinter withCompatibleJobs() {
    final compatibleRoles = roles.where(endpoint.canServe).toSet();
    final compatibleStations = endpoint.canServeKitchen
        ? kitchenStationIds
        : const <int>{};
    if (compatibleRoles.length == roles.length &&
        compatibleStations.length == kitchenStationIds.length) {
      return this;
    }
    return copyWith(
      roles: compatibleRoles,
      kitchenStationIds: compatibleStations,
    );
  }

  /// Whether [other] would save as exactly this printer.
  bool sameAs(DevicePrinter other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());

  factory DevicePrinter.fromJson(Map<String, Object?> json) {
    final configJson = json['config'];
    final rolesJson = json['roles'];
    final stationsJson = json['kitchen_station_ids'];
    return DevicePrinter(
      id: json['id']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      config: configJson is Map<String, Object?>
          ? PrinterConfig.fromJson(configJson)
          : PrinterConfig.defaultConfig(),
      roles: {
        if (rolesJson is List)
          for (final value in rolesJson) ?printerRoleFromJson(value),
      },
      kitchenStationIds: {
        if (stationsJson is List)
          for (final value in stationsJson)
            if (value is num)
              value.toInt()
            else if (int.tryParse('$value') case final int parsed)
              parsed,
      },
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'label': label,
      'config': config.toJson(),
      // Sorted, so saving the same printer twice writes the same bytes.
      'roles': [
        for (final role in PrinterRole.values)
          if (roles.contains(role)) printerRoleToJson(role),
      ],
      'kitchen_station_ids': kitchenStationIds.toList()..sort(),
    };
  }

  DevicePrinter copyWith({
    String? label,
    PrinterConfig? config,
    Set<PrinterRole>? roles,
    Set<int>? kitchenStationIds,
  }) {
    return DevicePrinter(
      id: id,
      label: label ?? this.label,
      config: config ?? this.config,
      roles: roles ?? this.roles,
      kitchenStationIds: kitchenStationIds ?? this.kitchenStationIds,
    );
  }
}

/// Every printer on this device.
///
/// Holds the one rule the whole feature rests on: a job has at most one
/// printer. Every write goes through here, and a printer that takes a job
/// takes it *from* whoever had it, so where a receipt prints is never a
/// question.
class DevicePrinters {
  const DevicePrinters([this.printers = const []]);

  static const empty = DevicePrinters();

  static const _version = 1;

  final List<DevicePrinter> printers;

  bool get isEmpty => printers.isEmpty;

  DevicePrinter? byId(String id) =>
      printers.where((printer) => printer.id == id).firstOrNull;

  DevicePrinter? holderOf(PrinterRole role) =>
      printers.where((printer) => printer.holds(role)).firstOrNull;

  DevicePrinter? kitchenPrinterFor(int stationId) => printers
      .where((printer) => printer.servesKitchenStation(stationId))
      .firstOrNull;

  /// The printer each kitchen station's chits go to, by station id.
  Map<int, PrinterConfig> get kitchenStationConfigs {
    return {
      for (final printer in printers)
        for (final stationId in printer.kitchenStationIds)
          stationId: printer.config,
    };
  }

  /// Adds [printer], or replaces the one with its id in place. The jobs it
  /// claims are taken from whichever printer had them.
  DevicePrinters upsert(DevicePrinter printer) {
    final incoming = printer.withCompatibleJobs();
    DevicePrinter release(DevicePrinter other) => other.copyWith(
      roles: other.roles.difference(incoming.roles),
      kitchenStationIds: other.kitchenStationIds.difference(
        incoming.kitchenStationIds,
      ),
    );

    final index = printers.indexWhere((other) => other.id == incoming.id);
    return DevicePrinters([
      for (final other in printers)
        if (other.id == incoming.id) incoming else release(other),
      if (index < 0) incoming,
    ]);
  }

  DevicePrinters remove(String printerId) {
    return DevicePrinters([
      for (final printer in printers)
        if (printer.id != printerId) printer,
    ]);
  }

  /// Hands [role] to the printer with [printerId], or to nobody when null.
  /// Refused (the list comes back unchanged) when that printer cannot do it.
  DevicePrinters assignRole(PrinterRole role, String? printerId) {
    final target = printerId == null ? null : byId(printerId);
    if (printerId != null &&
        (target == null || !target.endpoint.canServe(role))) {
      return this;
    }
    return DevicePrinters([
      for (final printer in printers)
        if (printer.id == printerId)
          printer.copyWith(roles: {...printer.roles, role})
        else
          printer.copyWith(roles: {...printer.roles}..remove(role)),
    ]);
  }

  /// Sends [stationId]'s chits to the printer with [printerId], or to no
  /// printer on this device when null (another device may serve it).
  DevicePrinters assignKitchenStation(int stationId, String? printerId) {
    final target = printerId == null ? null : byId(printerId);
    if (printerId != null &&
        (target == null || !target.endpoint.canServeKitchen)) {
      return this;
    }
    return DevicePrinters([
      for (final printer in printers)
        if (printer.id == printerId)
          printer.copyWith(
            kitchenStationIds: {...printer.kitchenStationIds, stationId},
          )
        else
          printer.copyWith(
            kitchenStationIds: {...printer.kitchenStationIds}
              ..remove(stationId),
          ),
    ]);
  }

  /// Reads a stored list, repairing what the invariant forbids: a job two
  /// printers claim stays with the first, a job a printer cannot do is
  /// dropped, and entries without an id are skipped.
  factory DevicePrinters.fromJson(Map<String, Object?> json) {
    final printersJson = json['printers'];
    var printers = DevicePrinters.empty;
    if (printersJson is List) {
      for (final entry in printersJson) {
        if (entry is! Map<String, Object?>) {
          continue;
        }
        final printer = DevicePrinter.fromJson(entry).withCompatibleJobs();
        if (printer.id.isEmpty || printers.byId(printer.id) != null) {
          continue;
        }
        final claimed = printer.copyWith(
          roles: printer.roles
              .where((role) => printers.holderOf(role) == null)
              .toSet(),
          kitchenStationIds: printer.kitchenStationIds
              .where((station) => printers.kitchenPrinterFor(station) == null)
              .toSet(),
        );
        printers = DevicePrinters([...printers.printers, claimed]);
      }
    }
    return printers;
  }

  Map<String, Object?> toJson() {
    return {
      'version': _version,
      'printers': [for (final printer in printers) printer.toJson()],
    };
  }
}

final _idRandom = Random();

/// A fresh [DevicePrinter.id]: time-ordered, with a random tail so two
/// printers added in the same instant still differ.
String newDevicePrinterId() {
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final salt = _idRandom.nextInt(1 << 30).toRadixString(36);
  return 'printer-$time-$salt';
}
