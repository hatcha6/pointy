import 'tracking_mode.dart';

/// One physical, individually identified article of stock.
///
/// A handset, a car, a generator — an article with its own cost, its own asking
/// price, its own place and its own life, whose identifier is unique only among
/// the units *currently in stock*. A phone sold and traded back in is two of
/// these with the same code, at most one of them live.
///
/// [incomingRate], [refurbCost] and [totalCost] are **absent** — not null, but
/// missing from the payload entirely — for a reader without
/// `inventory.view_stockunit_cost`. A used-goods shop does not show its counter
/// staff what it paid the walk-in seller, and a null cost and a hidden cost read
/// identically to a widget, so only one of them is allowed to exist.
class StockUnit {
  const StockUnit({
    required this.id,
    required this.variantId,
    required this.code,
    this.identifierKind = 'serial',
    this.secondaryCode = '',
    this.supplierCode = '',
    this.status = StockUnitStatus.inStock,
    this.warehouseId,
    this.warehouseName = '',
    this.productName = '',
    this.variantName = '',
    this.isIdentified = true,
    this.isConsignment = false,
    this.listPrice,
    this.soldPrice,
    this.incomingRate,
    this.refurbCost,
    this.totalCost,
    this.batchId,
    this.batchCode = '',
    this.batchExpiryDate,
    this.inStockSince,
    this.soldAt,
    this.attributes = const {},
    this.notes = '',
  });

  final int id;
  final int variantId;
  final String code;
  final String identifierKind;
  final String secondaryCode;
  final String supplierCode;
  final String status;
  final int? warehouseId;
  final String warehouseName;
  final String productName;
  final String variantName;

  /// False while the shop still owes this article its number — the other half
  /// of *capture later*. A placeholder counts in the bin and cannot be sold.
  final bool isIdentified;
  final bool isConsignment;

  /// This article's own asking price. Null means the variant's price stands.
  final double? listPrice;
  final double? soldPrice;

  /// Cost, when the reader is allowed to see it. See the class doc.
  final double? incomingRate;
  final double? refurbCost;
  final double? totalCost;

  final int? batchId;
  final String batchCode;
  final DateTime? batchExpiryDate;
  final DateTime? inStockSince;
  final DateTime? soldAt;
  final Map<String, Object?> attributes;
  final String notes;

  bool get isOnHand =>
      status == StockUnitStatus.inStock || status == StockUnitStatus.reserved;

  bool get isSellable => status == StockUnitStatus.inStock && isIdentified;

  /// Whether the reader was allowed to see what this article cost.
  bool get showsCost => totalCost != null;

  /// How long this article has been sitting on the shelf, which is what a
  /// used-goods trader is actually buying the picker for: stock ages, and an
  /// unsold handset loses value every week.
  int? get daysInStock {
    final since = inStockSince;
    if (since == null) {
      return null;
    }
    return DateTime.now().difference(since).inDays;
  }

  factory StockUnit.fromJson(Map<String, Object?> json) {
    return StockUnit(
      id: _intOf(json['id']),
      variantId: _intOf(json['variant']),
      code: json['code']?.toString() ?? '',
      identifierKind: json['identifier_kind']?.toString() ?? 'serial',
      secondaryCode: json['secondary_code']?.toString() ?? '',
      supplierCode: json['supplier_code']?.toString() ?? '',
      status: json['status']?.toString() ?? StockUnitStatus.inStock,
      warehouseId: _intOrNull(json['warehouse']),
      warehouseName: json['warehouse_name']?.toString() ?? '',
      productName: json['product_name']?.toString() ?? '',
      variantName: json['variant_name']?.toString() ?? '',
      isIdentified: json['is_identified'] != false,
      isConsignment: json['is_consignment'] == true,
      listPrice: _doubleOrNull(json['list_price']),
      soldPrice: _doubleOrNull(json['sold_price']),
      incomingRate: _doubleOrNull(json['incoming_rate']),
      refurbCost: _doubleOrNull(json['refurb_cost']),
      totalCost: _doubleOrNull(json['total_cost']),
      batchId: _intOrNull(json['batch']),
      batchCode: json['batch_code']?.toString() ?? '',
      batchExpiryDate: _dateOrNull(json['batch_expiry_date']),
      inStockSince: _dateOrNull(json['in_stock_since']),
      soldAt: _dateOrNull(json['sold_at']),
      attributes: json['attributes'] is Map<String, Object?>
          ? json['attributes']! as Map<String, Object?>
          : const {},
      notes: json['notes']?.toString() ?? '',
    );
  }
}

/// Mirrors `StockUnit.Status` on the backend. Strings rather than an enum
/// because the client only ever reads them, and an unknown value from a newer
/// backend must render rather than throw.
class StockUnitStatus {
  const StockUnitStatus._();

  static const expected = 'expected';
  static const inStock = 'in_stock';
  static const reserved = 'reserved';
  static const inTransit = 'in_transit';
  static const sold = 'sold';
  static const returned = 'returned';
  static const damaged = 'damaged';
  static const writtenOff = 'written_off';
  static const cancelled = 'cancelled';
}

/// A page of units, keyset-friendly: an offset page over a six-figure table is
/// a screen that gets slower every month it is used.
class StockUnitPage {
  const StockUnitPage({
    required this.units,
    this.count = 0,
    this.hasNext = false,
  });

  final List<StockUnit> units;
  final int count;
  final bool hasNext;

  factory StockUnitPage.fromJson(Object? decoded) {
    if (decoded is List<Object?>) {
      final units = decoded
          .whereType<Map<String, Object?>>()
          .map(StockUnit.fromJson)
          .toList(growable: false);
      return StockUnitPage(units: units, count: units.length);
    }
    if (decoded is! Map<String, Object?>) {
      return const StockUnitPage(units: []);
    }
    final results = decoded['results'];
    return StockUnitPage(
      units: results is List<Object?>
          ? results
                .whereType<Map<String, Object?>>()
                .map(StockUnit.fromJson)
                .toList(growable: false)
          : const [],
      count: _intOf(decoded['count']),
      hasNext: decoded['next'] != null,
    );
  }
}

/// What a scan of an identifier answered with: the live article, and the ones
/// that used to answer to the same code.
///
/// The second list is not an error and must never be rendered as one — it is
/// the trade-in, and the right thing to say is *«هذا الجهاز بيع من هذا المحل»*.
class StockUnitLookup {
  const StockUnitLookup({this.unit, this.history = const []});

  final StockUnit? unit;
  final List<StockUnit> history;

  bool get isLive => unit != null;

  bool get isReturningArticle => unit == null && history.isNotEmpty;

  factory StockUnitLookup.fromJson(Map<String, Object?> json) {
    final unitJson = json['unit'];
    final historyJson = json['history'];
    return StockUnitLookup(
      unit: unitJson is Map<String, Object?>
          ? StockUnit.fromJson(unitJson)
          : null,
      history: historyJson is List<Object?>
          ? historyJson
                .whereType<Map<String, Object?>>()
                .map(StockUnit.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

/// One line of an article's or a lot's life: what moved it, when, and at what
/// cost. The whole reason an allocation is a row rather than a text field on a
/// sale line.
class StockAllocationEntry {
  const StockAllocationEntry({
    required this.id,
    required this.direction,
    required this.quantity,
    this.unitCode = '',
    this.batchCode = '',
    this.warehouseName = '',
    this.rate,
    this.voucherType = '',
    this.voucherId,
    this.postingAt,
    this.note = '',
  });

  final int id;
  final String direction;
  final double quantity;
  final String unitCode;
  final String batchCode;
  final String warehouseName;
  final double? rate;
  final String voucherType;
  final int? voucherId;
  final DateTime? postingAt;
  final String note;

  bool get isIncoming => direction == 'in';

  factory StockAllocationEntry.fromJson(Map<String, Object?> json) {
    return StockAllocationEntry(
      id: _intOf(json['id']),
      direction: json['direction']?.toString() ?? '',
      quantity: _doubleOrNull(json['quantity']) ?? 0,
      unitCode: json['unit_code']?.toString() ?? '',
      batchCode: json['batch_code']?.toString() ?? '',
      warehouseName: json['warehouse_name']?.toString() ?? '',
      rate: _doubleOrNull(json['rate']),
      voucherType: json['voucher_type']?.toString() ?? '',
      voucherId: _intOrNull(json['voucher_id']),
      postingAt: _dateOrNull(json['posting_at']),
      note: json['note']?.toString() ?? '',
    );
  }
}

/// A unit's summary counts, plus what the shop still owes identifiers for.
class StockUnitSummary {
  const StockUnitSummary({
    this.byStatus = const {},
    this.missingIdentifiers = 0,
  });

  final Map<String, int> byStatus;
  final int missingIdentifiers;

  int get inStock => byStatus[StockUnitStatus.inStock] ?? 0;

  factory StockUnitSummary.fromJson(Map<String, Object?> json) {
    final raw = json['by_status'];
    return StockUnitSummary(
      byStatus: raw is Map<String, Object?>
          ? {for (final entry in raw.entries) entry.key: _intOf(entry.value)}
          : const {},
      missingIdentifiers: _intOf(json['missing_identifiers']),
    );
  }
}

int _intOf(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse((value ?? '').toString()) ?? 0;
}

int? _intOrNull(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  return int.tryParse(value.toString());
}

double? _doubleOrNull(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toDouble();
  }
  final text = value.toString();
  if (text.isEmpty) {
    return null;
  }
  return double.tryParse(text);
}

DateTime? _dateOrNull(Object? value) {
  final text = value?.toString() ?? '';
  if (text.isEmpty) {
    return null;
  }
  return DateTime.tryParse(text)?.toLocal();
}

/// Shared by the models in this file and by [TrackingMode]'s callers.
TrackingMode trackingModeOf(Object? value) => TrackingMode.fromWire(value);
