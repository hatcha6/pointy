import 'product_variant.dart';
import 'stock_batch.dart';
import 'stock_unit.dart';

/// What the server made of a scan the till could not answer for itself.
///
/// Three things reach here and nothing else does: a live article's identifier,
/// a lot barcode, and a GS1 element string — the symbol on a pharmaceutical
/// pack that names a trade item, a lot, an expiry and a serial all at once. A
/// plain barcode never gets this far, which is what keeps this whole path
/// invisible to a shop that sells Coca-Cola.
class TrackedScan {
  const TrackedScan({
    this.kind = TrackedScanKind.none,
    this.variant,
    this.unit,
    this.batch,
    this.expiryDate,
    this.warnings = const [],
  });

  final String kind;
  final ProductVariant? variant;
  final StockUnit? unit;
  final StockBatch? batch;
  final DateTime? expiryDate;

  /// Everything the server could read but does not trust: a scanner that strips
  /// the group separator, an expiry on the box that disagrees with the lot, a
  /// GTIN nobody has registered. Shown, never swallowed — each one is a
  /// sentence somebody holding the box can act on.
  final List<TrackedScanWarning> warnings;

  bool get found => kind != TrackedScanKind.none;

  bool get isUnit => unit != null;

  bool get isGs1 => kind == TrackedScanKind.gs1;

  /// The price this line should ring up at: the article's own asking price when
  /// it has one, else the variant's. Resolved once, here, so the till and the
  /// backend can never disagree about which price won.
  double? get resolvedUnitPrice => unit?.listPrice ?? variant?.unitPrice;

  factory TrackedScan.fromJson(Map<String, Object?> json) {
    final variantJson = json['variant'];
    final unitJson = json['stock_unit'];
    final batchJson = json['stock_batch'];
    final warningsJson = json['warnings'];
    return TrackedScan(
      kind: json['kind']?.toString() ?? TrackedScanKind.none,
      variant: variantJson is Map<String, Object?>
          ? ProductVariant.fromJson(_variantPayload(variantJson))
          : null,
      unit: unitJson is Map<String, Object?>
          ? StockUnit.fromJson(unitJson)
          : null,
      batch: batchJson is Map<String, Object?>
          ? StockBatch.fromJson(batchJson)
          : null,
      expiryDate: _dateOrNull(json['expiry_date']),
      warnings: warningsJson is List<Object?>
          ? warningsJson
                .whereType<Map<String, Object?>>()
                .map(TrackedScanWarning.fromJson)
                .toList(growable: false)
          : const [],
    );
  }

  /// The resolve endpoint nests the product under `product`; [ProductVariant]
  /// expects it under `product_detail` and the id under `product`. Reshaped
  /// here rather than in the model, so the model keeps one wire contract.
  static Map<String, Object?> _variantPayload(Map<String, Object?> json) {
    final product = json['product'];
    if (product is! Map<String, Object?>) {
      return json;
    }
    return {
      ...json,
      'product': product['id'],
      'product_detail': product,
      'product_name': product['name'],
      'is_service': product['is_service'],
      'is_prepared': product['is_prepared'],
      'unit': product['unit'],
    };
  }
}

class TrackedScanKind {
  const TrackedScanKind._();

  static const none = 'none';
  static const variant = 'variant';
  static const stockUnit = 'stock_unit';
  static const stockBatch = 'stock_batch';
  static const gs1 = 'gs1';
}

/// Something the scan said that the shop should look at.
///
/// [code] is stable and machine-readable so a caller can single out the one
/// that matters — `missing_group_separator` is a scanner configuration problem
/// and deserves its own dialog, while `unknown_lot` is a receiving problem.
class TrackedScanWarning {
  const TrackedScanWarning({
    required this.code,
    required this.message,
    this.ai = '',
    this.value = '',
  });

  final String code;
  final String message;
  final String ai;
  final String value;

  /// The reader itself is misconfigured, which is the one warning worth
  /// interrupting somebody over: every scan of every pack will be wrong until
  /// it is fixed.
  bool get isScannerConfiguration => code == 'missing_group_separator';

  factory TrackedScanWarning.fromJson(Map<String, Object?> json) {
    return TrackedScanWarning(
      code: json['code']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
      ai: json['ai']?.toString() ?? '',
      value: json['value']?.toString() ?? '',
    );
  }
}

DateTime? _dateOrNull(Object? value) {
  final text = value?.toString() ?? '';
  if (text.isEmpty) {
    return null;
  }
  return DateTime.tryParse(text)?.toLocal();
}
