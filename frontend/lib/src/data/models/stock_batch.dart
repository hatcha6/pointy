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

/// Everything a recall needs about one lot, in one answer (§6.8.1).
///
/// Answered against **one lot row**, whatever branches its goods passed
/// through — which is the whole argument for the identity/balance split. A
/// recall under a warehouse-scoped batch table had to find the pieces by
/// string-matching a code.
class BatchRecallReport {
  const BatchRecallReport({
    required this.batchId,
    required this.batchCode,
    required this.productName,
    required this.isLocked,
    required this.status,
    required this.inward,
    required this.remaining,
    required this.outward,
    required this.subLots,
    required this.customersReachable,
    required this.customersUnreachable,
    required this.walkInSales,
    this.expiryDate,
  });

  final int batchId;
  final String batchCode;
  final String productName;
  final bool isLocked;
  final String status;
  final DateTime? expiryDate;

  /// Supplier, delivery, order, quantity.
  final List<RecallInwardRow> inward;

  /// Every warehouse still holding any of it, awaiting return or disposal.
  final List<RecallRemainingRow> remaining;

  /// Who walked out with the rest. Under `serial_batch` this names the exact
  /// pack, which is what lets a pharmacist tell a customer whether *their*
  /// box is the recalled one.
  final List<RecallOutwardRow> outward;

  /// Sub-lots created by repacking, swept by the same report.
  final List<({int id, String code})> subLots;

  final int customersReachable;
  final int customersUnreachable;

  /// Sales with no customer on the invoice. Counted rather than quietly
  /// dropped: that is the number that tells a pharmacist to put a sign up.
  final int walkInSales;

  factory BatchRecallReport.fromJson(Map<String, Object?> json) {
    List<T> rows<T>(String key, T Function(Map<String, Object?>) build) {
      final raw = json[key];
      if (raw is! List) {
        return <T>[];
      }
      return raw.whereType<Map<String, Object?>>().map(build).toList();
    }

    return BatchRecallReport(
      batchId: (json['batch'] as num?)?.toInt() ?? 0,
      batchCode: json['batch_code']?.toString() ?? '',
      productName: json['product_name']?.toString() ?? '',
      isLocked: json['is_locked'] == true,
      status: json['status']?.toString() ?? '',
      expiryDate: json['expiry_date'] == null
          ? null
          : DateTime.tryParse('${json['expiry_date']}'),
      inward: rows('inward', RecallInwardRow.fromJson),
      remaining: rows('remaining', RecallRemainingRow.fromJson),
      outward: rows('outward', RecallOutwardRow.fromJson),
      subLots: rows(
        'sub_lots',
        (row) => (
          id: (row['id'] as num?)?.toInt() ?? 0,
          code: row['code']?.toString() ?? '',
        ),
      ),
      customersReachable: (json['customers_reachable'] as num?)?.toInt() ?? 0,
      customersUnreachable:
          (json['customers_unreachable'] as num?)?.toInt() ?? 0,
      walkInSales: (json['walk_in_sales'] as num?)?.toInt() ?? 0,
    );
  }
}

class RecallInwardRow {
  const RecallInwardRow({
    required this.batchCode,
    required this.supplierName,
    required this.quantity,
    this.receivedAt,
  });

  final String batchCode;
  final String supplierName;
  final double quantity;
  final DateTime? receivedAt;

  factory RecallInwardRow.fromJson(Map<String, Object?> json) {
    return RecallInwardRow(
      batchCode: json['batch_code']?.toString() ?? '',
      supplierName: json['supplier_name']?.toString() ?? '',
      quantity: double.tryParse('${json['quantity']}') ?? 0,
      receivedAt: DateTime.tryParse('${json['received_at']}'),
    );
  }
}

class RecallRemainingRow {
  const RecallRemainingRow({
    required this.batchCode,
    required this.warehouseName,
    required this.remaining,
    required this.isSellable,
  });

  final String batchCode;
  final String warehouseName;
  final double remaining;
  final bool isSellable;

  factory RecallRemainingRow.fromJson(Map<String, Object?> json) {
    return RecallRemainingRow(
      batchCode: json['batch_code']?.toString() ?? '',
      warehouseName: json['warehouse_name']?.toString() ?? '',
      remaining: double.tryParse('${json['remaining']}') ?? 0,
      isSellable: json['is_sellable'] == true,
    );
  }
}

class RecallOutwardRow {
  const RecallOutwardRow({
    required this.invoiceNumber,
    required this.quantity,
    this.soldAt,
    this.unitCode = '',
    this.customerName = '',
    this.customerPhone = '',
  });

  final String invoiceNumber;
  final double quantity;
  final DateTime? soldAt;
  final String unitCode;
  final String customerName;
  final String customerPhone;

  factory RecallOutwardRow.fromJson(Map<String, Object?> json) {
    return RecallOutwardRow(
      invoiceNumber: json['invoice_number']?.toString() ?? '',
      quantity: double.tryParse('${json['quantity']}') ?? 0,
      soldAt: DateTime.tryParse('${json['sold_at']}'),
      unitCode: json['unit_code']?.toString() ?? '',
      customerName: json['customer_name']?.toString() ?? '',
      customerPhone: json['customer_phone']?.toString() ?? '',
    );
  }
}

/// What the recall broadcast did. Deduplicated per customer per recall: a
/// pharmacist who taps twice must not frighten the same person twice.
class RecallNotifyResult {
  const RecallNotifyResult({
    required this.queued,
    required this.unreachable,
    required this.walkInSales,
  });

  final int queued;
  final int unreachable;
  final int walkInSales;

  factory RecallNotifyResult.fromJson(Map<String, Object?> json) {
    return RecallNotifyResult(
      queued: (json['queued'] as num?)?.toInt() ?? 0,
      unreachable: (json['unreachable'] as num?)?.toInt() ?? 0,
      walkInSales: (json['walk_in_sales'] as num?)?.toInt() ?? 0,
    );
  }
}

/// What to cut, and what it saves. Advice, never an action — nothing here
/// changes a price.
class ExpiryMarkdownSuggestion {
  const ExpiryMarkdownSuggestion({
    required this.daysLeft,
    required this.discountPct,
    required this.currentPrice,
    required this.suggestedPrice,
    required this.quantity,
    required this.writeOffAvoided,
    required this.atCostFloor,
  });

  final int daysLeft;
  final double discountPct;
  final double currentPrice;
  final double suggestedPrice;
  final double quantity;

  /// The write-off avoided, not the discount given: the shop is choosing
  /// between *sell it at 6* and *bin it at 10*, and a report that showed the
  /// discount as a loss would argue for doing nothing.
  final double writeOffAvoided;

  /// Whether the ladder's price was clamped up to the lot's own cost.
  final bool atCostFloor;

  factory ExpiryMarkdownSuggestion.fromJson(Map<String, Object?> json) {
    double number(Object? value) => double.tryParse('$value') ?? 0;
    return ExpiryMarkdownSuggestion(
      daysLeft: (json['days_left'] as num?)?.toInt() ?? 0,
      discountPct: number(json['discount_pct']),
      currentPrice: number(json['current_price']),
      suggestedPrice: number(json['suggested_price']),
      quantity: number(json['quantity']),
      writeOffAvoided: number(json['write_off_avoided']),
      atCostFloor: json['at_cost_floor'] == true,
    );
  }
}
