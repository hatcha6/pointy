/// A production lot, and where its goods currently are.
///
/// The lot is an **identity**, never a place and never a quantity: one lot code
/// means one lot for the life of the shop, wherever its goods sit. How much of
/// it is in each warehouse is [balances], one row per place — which is what
/// makes "where is Lot A?" a question with a single answer, and a recall one
/// write rather than one per branch with a window in between where the second
/// branch is still selling.
class StockBatch {
  const StockBatch({
    required this.id,
    required this.variantId,
    required this.code,
    this.displayCode = '',
    this.codeIsGenerated = false,
    this.gtin = '',
    this.barcode = '',
    this.expiryDate,
    this.manufacturedOn,
    this.status = StockBatchStatus.active,
    this.isLocked = false,
    this.isSellable = true,
    this.supplierId,
    this.productName = '',
    this.variantName = '',
    this.balances = const [],
    this.onHand = 0,
    this.notes = '',
  });

  final int id;
  final int variantId;

  /// The stored code, which may be one this shop generated for goods that
  /// arrived unlabelled.
  final String code;

  /// Blank when the code was generated, so the UI can honestly render
  /// «بدون رقم دفعة» instead of a number nobody printed on a box.
  final String displayCode;
  final bool codeIsGenerated;
  final String gtin;
  final String barcode;

  /// Nullable, because non-expiring lots exist: a tyre's DOT week, a tile's dye
  /// lot, a battery's production run.
  final DateTime? expiryDate;
  final DateTime? manufacturedOn;
  final String status;

  /// The recall stop-sale flag. Quarantine does not remove goods from the
  /// shelf — it stops them leaving; scrapping them is a separate act.
  final bool isLocked;
  final bool isSellable;
  final int? supplierId;
  final String productName;
  final String variantName;
  final List<StockBatchBalance> balances;

  /// Across every place it sits.
  final double onHand;
  final String notes;

  bool get isQuarantined => status == StockBatchStatus.quarantined;

  bool get isExpired {
    final expiry = expiryDate;
    if (expiry == null) {
      return false;
    }
    final today = DateTime.now();
    return expiry.isBefore(DateTime(today.year, today.month, today.day));
  }

  /// Negative once it has passed. Null for a lot that never expires.
  int? get daysUntilExpiry {
    final expiry = expiryDate;
    if (expiry == null) {
      return null;
    }
    final now = DateTime.now();
    return DateTime(
      expiry.year,
      expiry.month,
      expiry.day,
    ).difference(DateTime(now.year, now.month, now.day)).inDays;
  }

  /// What the shop would call this lot out loud.
  String get label => displayCode.isNotEmpty ? displayCode : '';

  double quantityAt(int? warehouseId) {
    if (warehouseId == null) {
      return onHand;
    }
    for (final balance in balances) {
      if (balance.warehouseId == warehouseId) {
        return balance.remainingQuantity;
      }
    }
    return 0;
  }

  factory StockBatch.fromJson(Map<String, Object?> json) {
    final balancesJson = json['balances'];
    return StockBatch(
      id: _intOf(json['id']),
      variantId: _intOf(json['variant']),
      code: json['code']?.toString() ?? '',
      displayCode: json['display_code']?.toString() ?? '',
      codeIsGenerated: json['code_is_generated'] == true,
      gtin: json['gtin']?.toString() ?? '',
      barcode: json['barcode']?.toString() ?? '',
      expiryDate: _dateOrNull(json['expiry_date']),
      manufacturedOn: _dateOrNull(json['manufactured_on']),
      status: json['status']?.toString() ?? StockBatchStatus.active,
      isLocked: json['is_locked'] == true,
      isSellable: json['is_sellable'] != false,
      supplierId: _intOrNull(json['supplier']),
      productName: json['product_name']?.toString() ?? '',
      variantName: json['variant_name']?.toString() ?? '',
      balances: balancesJson is List<Object?>
          ? balancesJson
                .whereType<Map<String, Object?>>()
                .map(StockBatchBalance.fromJson)
                .toList(growable: false)
          : const [],
      onHand: _doubleOrNull(json['on_hand']) ?? 0,
      notes: json['notes']?.toString() ?? '',
    );
  }
}

/// How much of one lot is sitting in one place.
///
/// Kept even at zero, because "Lot A was in Branch #2 and is not any more" is
/// exactly the sentence a recall needs.
class StockBatchBalance {
  const StockBatchBalance({
    required this.id,
    required this.batchId,
    required this.warehouseId,
    this.warehouseName = '',
    this.receivedQuantity = 0,
    this.remainingQuantity = 0,
    this.incomingRate = 0,
    this.expiryDate,
    this.isSellable = true,
  });

  final int id;
  final int batchId;
  final int warehouseId;
  final String warehouseName;
  final double receivedQuantity;
  final double remainingQuantity;

  /// Cost sits with the quantity, because value is quantity × rate and quantity
  /// is here.
  final double incomingRate;

  /// Copied from the lot so the till's FEFO lookup is one indexed scan of one
  /// table. Never edited here — it is the lot that owns it.
  final DateTime? expiryDate;
  final bool isSellable;

  bool get isEmpty => remainingQuantity <= 0;

  factory StockBatchBalance.fromJson(Map<String, Object?> json) {
    return StockBatchBalance(
      id: _intOf(json['id']),
      batchId: _intOf(json['batch']),
      warehouseId: _intOf(json['warehouse']),
      warehouseName: json['warehouse_name']?.toString() ?? '',
      receivedQuantity: _doubleOrNull(json['received_quantity']) ?? 0,
      remainingQuantity: _doubleOrNull(json['remaining_quantity']) ?? 0,
      incomingRate: _doubleOrNull(json['incoming_rate']) ?? 0,
      expiryDate: _dateOrNull(json['expiry_date']),
      isSellable: json['is_sellable'] != false,
    );
  }
}

class StockBatchStatus {
  const StockBatchStatus._();

  static const active = 'active';
  static const quarantined = 'quarantined';
  static const expired = 'expired';
}

class StockBatchPage {
  const StockBatchPage({
    required this.batches,
    this.count = 0,
    this.hasNext = false,
  });

  final List<StockBatch> batches;
  final int count;
  final bool hasNext;

  factory StockBatchPage.fromJson(Object? decoded) {
    if (decoded is List<Object?>) {
      final batches = decoded
          .whereType<Map<String, Object?>>()
          .map(StockBatch.fromJson)
          .toList(growable: false);
      return StockBatchPage(batches: batches, count: batches.length);
    }
    if (decoded is! Map<String, Object?>) {
      return const StockBatchPage(batches: []);
    }
    final results = decoded['results'];
    return StockBatchPage(
      batches: results is List<Object?>
          ? results
                .whereType<Map<String, Object?>>()
                .map(StockBatch.fromJson)
                .toList(growable: false)
          : const [],
      count: _intOf(decoded['count']),
      hasNext: decoded['next'] != null,
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
