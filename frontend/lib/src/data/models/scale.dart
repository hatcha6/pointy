import 'dart:convert';

/// One label-printing scale on the shop's counter.
class Scale {
  const Scale({
    required this.id,
    required this.name,
    required this.driver,
    this.driverLabel = '',
    this.needsAddress = true,
    this.host = '',
    this.port = 0,
    this.department = 1,
    this.options = const {},
    this.barcodeRuleId,
    this.isActive = true,
    this.lastPushAt,
    this.notes = '',
  });

  factory Scale.fromJson(Map<String, dynamic> json) {
    return Scale(
      id: json['id'] as int,
      name: json['name']?.toString() ?? '',
      driver: json['driver']?.toString() ?? '',
      driverLabel: json['driver_label']?.toString() ?? '',
      needsAddress: json['needs_address'] != false,
      host: json['host']?.toString() ?? '',
      port: int.tryParse(json['port']?.toString() ?? '') ?? 0,
      department: int.tryParse(json['department']?.toString() ?? '') ?? 1,
      options: json['options'] is Map
          ? Map<String, Object?>.from(json['options'] as Map)
          : const {},
      barcodeRuleId: json['barcode_rule'] is int
          ? json['barcode_rule'] as int
          : null,
      isActive: json['is_active'] != false,
      lastPushAt: DateTime.tryParse(json['last_push_at']?.toString() ?? ''),
      notes: json['notes']?.toString() ?? '',
    );
  }

  final int id;
  final String name;
  final String driver;
  final String driverLabel;
  final bool needsAddress;
  final String host;
  final int port;
  final int department;
  final Map<String, Object?> options;
  final int? barcodeRuleId;
  final bool isActive;
  final DateTime? lastPushAt;
  final String notes;

  Map<String, Object?> toDraft() => {
    'name': name,
    'driver': driver,
    'host': host,
    'port': port,
    'department': department,
    'options': options,
    'barcode_rule': barcodeRuleId,
    'is_active': isActive,
    'notes': notes,
  };
}

/// A scale type the backend knows how to talk to.
class ScaleDriverInfo {
  const ScaleDriverInfo({
    required this.key,
    required this.label,
    required this.needsAddress,
    required this.defaultPort,
  });

  factory ScaleDriverInfo.fromJson(Map<String, dynamic> json) {
    return ScaleDriverInfo(
      key: json['key']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      needsAddress: json['needs_address'] != false,
      defaultPort: int.tryParse(json['default_port']?.toString() ?? '') ?? 0,
    );
  }

  final String key;
  final String label;
  final bool needsAddress;
  final int defaultPort;
}

/// One attempt at making a scale agree with the catalog.
class ScalePushJob {
  const ScalePushJob({
    required this.id,
    required this.status,
    this.pluCount = 0,
    this.sentCount = 0,
    this.failedCount = 0,
    this.errors = const {},
    this.message = '',
    this.filename = '',
    this.finishedAt,
    this.requestedByName = '',
  });

  factory ScalePushJob.fromJson(Map<String, dynamic> json) {
    final rawErrors = json['errors'];
    return ScalePushJob(
      id: json['id'] as int,
      status: json['status']?.toString() ?? '',
      pluCount: int.tryParse(json['plu_count']?.toString() ?? '') ?? 0,
      sentCount: int.tryParse(json['sent_count']?.toString() ?? '') ?? 0,
      failedCount: int.tryParse(json['failed_count']?.toString() ?? '') ?? 0,
      errors: rawErrors is Map
          ? {
              for (final entry in rawErrors.entries)
                entry.key.toString(): entry.value.toString(),
            }
          : const {},
      message: json['message']?.toString() ?? '',
      filename: json['filename']?.toString() ?? '',
      finishedAt: DateTime.tryParse(json['finished_at']?.toString() ?? ''),
      requestedByName: json['requested_by_name']?.toString() ?? '',
    );
  }

  final int id;
  final String status;
  final int pluCount;
  final int sentCount;
  final int failedCount;
  final Map<String, String> errors;
  final String message;
  final String filename;
  final DateTime? finishedAt;
  final String requestedByName;

  /// Whether the scale itself now holds these prices. A produced file does not
  /// count: somebody still has to carry it over.
  bool get delivered => status == 'succeeded';

  bool get isFailure => status == 'failed';
}

/// The number a product answers to on the shop's scales.
class ScalePlu {
  const ScalePlu({
    required this.id,
    required this.variantId,
    required this.pluNumber,
    this.productName = '',
    this.variantName = '',
    this.labelName = '',
    this.printedName = '',
    this.tareGrams = 0,
    this.shelfLifeDays,
    this.isActive = true,
  });

  factory ScalePlu.fromJson(Map<String, dynamic> json) {
    return ScalePlu(
      id: json['id'] as int,
      variantId: int.tryParse(json['variant']?.toString() ?? '') ?? 0,
      pluNumber: int.tryParse(json['plu_number']?.toString() ?? '') ?? 0,
      productName: json['product_name']?.toString() ?? '',
      variantName: json['variant_name']?.toString() ?? '',
      labelName: json['label_name']?.toString() ?? '',
      printedName: json['printed_name']?.toString() ?? '',
      tareGrams: int.tryParse(json['tare_grams']?.toString() ?? '') ?? 0,
      shelfLifeDays: int.tryParse(json['shelf_life_days']?.toString() ?? ''),
      isActive: json['is_active'] != false,
    );
  }

  final int id;
  final int variantId;
  final int pluNumber;
  final String productName;
  final String variantName;
  final String labelName;
  final String printedName;
  final int tareGrams;
  final int? shelfLifeDays;
  final bool isActive;
}

/// Whether a scale answered when we knocked.
class ScaleReachability {
  const ScaleReachability({required this.reachable, this.detail = ''});

  factory ScaleReachability.fromJson(Map<String, dynamic> json) {
    return ScaleReachability(
      reachable: json['reachable'] == true,
      detail: json['detail']?.toString() ?? '',
    );
  }

  final bool reachable;
  final String detail;
}

/// Decoding helper for endpoints that answer with a bare list.
List<Map<String, dynamic>> decodeJsonList(String body) {
  final decoded = jsonDecode(body);
  if (decoded is List) {
    return decoded.whereType<Map<String, dynamic>>().toList(growable: false);
  }
  return const [];
}
