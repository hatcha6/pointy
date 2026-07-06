part of 'purchase_submission.dart';

enum PurchaseAdjustmentType {
  returnItems('return'),
  refund('refund'),
  exchange('exchange');

  const PurchaseAdjustmentType(this.apiValue);

  final String apiValue;

  static PurchaseAdjustmentType fromApiValue(Object? value) {
    return switch (value?.toString()) {
      'refund' => PurchaseAdjustmentType.refund,
      'exchange' => PurchaseAdjustmentType.exchange,
      _ => PurchaseAdjustmentType.returnItems,
    };
  }
}

class PurchaseOrderAdjustment {
  const PurchaseOrderAdjustment({
    required this.id,
    required this.type,
    required this.amount,
    required this.lines,
    required this.replacementLines,
    required this.credits,
    this.reason = '',
    this.settlementMethod,
    this.refundMethod,
    this.createdByUsername,
    this.createdAt,
  });

  final int id;
  final PurchaseAdjustmentType type;
  final double amount;
  final String reason;
  final String? settlementMethod;
  final String? refundMethod;
  final String? createdByUsername;
  final List<PurchaseOrderAdjustmentLine> lines;
  final List<PurchaseOrderReplacementLine> replacementLines;
  final List<SupplierCredit> credits;
  final DateTime? createdAt;

  factory PurchaseOrderAdjustment.fromJson(Map<String, Object?> json) {
    final lines = json['lines'] is List<Object?>
        ? json['lines'] as List<Object?>
        : const <Object?>[];
    final credits = json['credits'] is List<Object?>
        ? json['credits'] as List<Object?>
        : [
            if (json['supplier_credit'] is Map<String, Object?>)
              json['supplier_credit'],
          ];
    return PurchaseOrderAdjustment(
      id: _intFromJson(json['id']),
      type: PurchaseAdjustmentType.fromApiValue(json['adjustment_type']),
      amount: _moneyFromJson(json['amount']),
      reason: json['reason']?.toString() ?? '',
      settlementMethod: json['settlement_method']?.toString(),
      refundMethod: json['refund_method']?.toString(),
      createdByUsername: json['created_by_username']?.toString(),
      lines: lines
          .whereType<Map<String, Object?>>()
          .map(PurchaseOrderAdjustmentLine.fromJson)
          .toList(growable: false),
      replacementLines:
          _listFromJson(
                json['replacement_lines'] ??
                    json['replacements'] ??
                    json['inbound_lines'],
              )
              .whereType<Map<String, Object?>>()
              .map(PurchaseOrderReplacementLine.fromJson)
              .toList(growable: false),
      credits: credits
          .whereType<Map<String, Object?>>()
          .map(SupplierCredit.fromJson)
          .toList(growable: false),
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

class PurchaseAdjustmentHistoryEntry {
  const PurchaseAdjustmentHistoryEntry({
    required this.id,
    required this.type,
    required this.amount,
    required this.lines,
    required this.replacementLines,
    this.purchaseOrderId,
    this.purchaseOrderNumber,
    this.supplierId,
    this.supplierName,
    this.reason = '',
    this.settlementMethod,
    this.refundMethod,
    this.createdAt,
  });

  final int id;
  final PurchaseAdjustmentType type;
  final int? purchaseOrderId;
  final String? purchaseOrderNumber;
  final int? supplierId;
  final String? supplierName;
  final double amount;
  final String reason;
  final String? settlementMethod;
  final String? refundMethod;
  final List<PurchaseOrderAdjustmentLine> lines;
  final List<PurchaseOrderReplacementLine> replacementLines;
  final DateTime? createdAt;

  factory PurchaseAdjustmentHistoryEntry.fromJson(Map<String, Object?> json) {
    final nestedLines = _listFromJson(json['lines']);
    final hasFlatLine =
        nestedLines.isEmpty &&
        (json.containsKey('purchase_line') || json.containsKey('product'));
    final adjustment = PurchaseOrderAdjustment.fromJson({
      ...json,
      'id': json['adjustment'] ?? json['adjustment_id'] ?? json['id'],
      'amount': json['amount'] ?? json['adjustment_amount'],
      if (hasFlatLine) 'lines': [json],
    });
    return PurchaseAdjustmentHistoryEntry(
      id: adjustment.id,
      type: adjustment.type,
      purchaseOrderId: _nullableIntFromJson(
        json['purchase_order'] ?? json['purchase_order_id'] ?? json['order'],
      ),
      purchaseOrderNumber:
          json['purchase_order_number']?.toString() ??
          json['order_number']?.toString(),
      supplierId: _nullableIntFromJson(json['supplier'] ?? json['supplier_id']),
      supplierName: json['supplier_name']?.toString(),
      amount: adjustment.amount,
      reason: adjustment.reason,
      settlementMethod: adjustment.settlementMethod,
      refundMethod: adjustment.refundMethod,
      lines: adjustment.lines,
      replacementLines: adjustment.replacementLines,
      createdAt: adjustment.createdAt,
    );
  }
}

class PurchaseAdjustmentHistoryPage {
  const PurchaseAdjustmentHistoryPage({
    required this.entries,
    required this.hasMore,
  });

  final List<PurchaseAdjustmentHistoryEntry> entries;
  final bool hasMore;

  factory PurchaseAdjustmentHistoryPage.fromAny(Object? json) {
    if (json is List<Object?>) {
      return PurchaseAdjustmentHistoryPage(
        entries: json
            .whereType<Map<String, Object?>>()
            .map(PurchaseAdjustmentHistoryEntry.fromJson)
            .toList(growable: false),
        hasMore: false,
      );
    }
    if (json is Map<String, Object?>) {
      final rawEntries = _listFromJson(
        json['results'] ?? json['adjustments'] ?? json['history'],
      );
      return PurchaseAdjustmentHistoryPage(
        entries: rawEntries
            .whereType<Map<String, Object?>>()
            .map(PurchaseAdjustmentHistoryEntry.fromJson)
            .toList(growable: false),
        hasMore: json['next'] != null,
      );
    }
    return const PurchaseAdjustmentHistoryPage(entries: [], hasMore: false);
  }
}

class SupplierCredit {
  const SupplierCredit({
    required this.id,
    required this.amount,
    this.remainingAmount,
    this.createdAt,
  });

  final int id;
  final double amount;
  final double? remainingAmount;
  final DateTime? createdAt;

  factory SupplierCredit.fromJson(Map<String, Object?> json) {
    return SupplierCredit(
      id: _intFromJson(json['id']),
      amount: _moneyFromJson(json['amount']),
      remainingAmount: _nullableMoneyFromJson(
        json['remaining_amount'] ??
            json['balance'] ??
            json['balance_remaining'],
      ),
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

class PurchaseOrderAdjustmentLine {
  const PurchaseOrderAdjustmentLine({
    required this.id,
    required this.purchaseLineId,
    required this.productId,
    required this.variantId,
    required this.quantity,
    required this.unitCost,
    required this.total,
    this.productName,
    this.variantName,
    this.variantSku,
  });

  final int id;
  final int purchaseLineId;
  final int productId;
  final int variantId;
  final String? productName;
  final String? variantName;
  final String? variantSku;
  final double quantity;
  final double unitCost;
  final double total;

  String get displayName => _variantDisplayName(productName, variantName);

  factory PurchaseOrderAdjustmentLine.fromJson(Map<String, Object?> json) {
    return PurchaseOrderAdjustmentLine(
      id: _intFromJson(json['id']),
      purchaseLineId: _intFromJson(json['purchase_line']),
      productId: _intFromJson(json['product']),
      variantId: _intFromJson(
        json['variant'] ?? json['variant_id'] ?? json['product'],
      ),
      productName: json['product_name']?.toString(),
      variantName: json['variant_name']?.toString(),
      variantSku: json['variant_sku']?.toString(),
      quantity: _quantityFromJson(json['quantity']),
      unitCost: _moneyFromJson(json['unit_cost']),
      total: _moneyFromJson(json['line_total']),
    );
  }
}

class PurchaseOrderReplacementLine {
  const PurchaseOrderReplacementLine({
    required this.productId,
    required this.variantId,
    required this.quantity,
    required this.unitCost,
    required this.total,
    this.productName,
    this.variantName,
  });

  final int productId;
  final int variantId;
  final String? productName;
  final String? variantName;
  final double quantity;
  final double unitCost;
  final double total;

  String get displayName => _variantDisplayName(productName, variantName);

  factory PurchaseOrderReplacementLine.fromJson(Map<String, Object?> json) {
    return PurchaseOrderReplacementLine(
      productId: _intFromJson(json['product']),
      variantId: _intFromJson(
        json['variant'] ?? json['variant_id'] ?? json['product'],
      ),
      productName: json['product_name']?.toString(),
      variantName: json['variant_name']?.toString(),
      quantity: _quantityFromJson(json['quantity']),
      unitCost: _moneyFromJson(json['unit_cost']),
      total: _moneyFromJson(
        json['line_total'] ?? json['total'] ?? json['amount'],
      ),
    );
  }
}

class PurchaseAdjustmentDraft {
  const PurchaseAdjustmentDraft({
    required this.lines,
    this.replacementLines = const [],
    this.reason = '',
  });

  final List<PurchaseAdjustmentLineDraft> lines;
  final List<PurchaseReplacementLineDraft> replacementLines;
  final String reason;

  Map<String, Object?> toJson() {
    return {
      'reason': reason,
      'lines': lines.map((line) => line.toJson()).toList(growable: false),
      if (replacementLines.isNotEmpty)
        'replacement_lines': replacementLines
            .map((line) => line.toJson())
            .toList(growable: false),
    };
  }
}

class PurchaseAdjustmentLineDraft {
  const PurchaseAdjustmentLineDraft({
    required this.lineId,
    required this.quantity,
  });

  final int lineId;
  final double quantity;

  Map<String, Object?> toJson() {
    return {'line': lineId, 'quantity': quantity.toStringAsFixed(3)};
  }
}

class PurchaseReplacementLineDraft {
  const PurchaseReplacementLineDraft({
    required this.variantId,
    required this.quantity,
    required this.unitCost,
  });

  final int variantId;
  final double quantity;
  final double unitCost;

  Map<String, Object?> toJson() {
    return {
      'variant': variantId,
      'quantity': quantity.toStringAsFixed(3),
      'unit_cost': unitCost.toStringAsFixed(2),
    };
  }
}

enum SupplierPaymentMethod {
  cash('cash'),
  card('card'),
  transfer('transfer'),
  supplierCredit('supplier_credit'),
  refund('refund');

  const SupplierPaymentMethod(this.apiValue);

  final String apiValue;

  static SupplierPaymentMethod fromApiValue(Object? value) {
    return switch (value?.toString()) {
      'card' => SupplierPaymentMethod.card,
      'transfer' || 'bank_transfer' => SupplierPaymentMethod.transfer,
      'supplier_credit' => SupplierPaymentMethod.supplierCredit,
      'refund' => SupplierPaymentMethod.refund,
      _ => SupplierPaymentMethod.cash,
    };
  }
}

class SupplierPaymentDraft {
  const SupplierPaymentDraft({
    required this.amount,
    required this.method,
    this.supplierId,
    this.purchaseOrderId,
    this.reference = '',
    this.notes = '',
  });

  final int? supplierId;
  final int? purchaseOrderId;
  final double amount;
  final SupplierPaymentMethod method;
  final String reference;
  final String notes;

  Map<String, Object?> toJson() {
    return {
      if (supplierId != null) 'supplier': supplierId,
      if (purchaseOrderId != null) 'purchase_order': purchaseOrderId,
      'amount': amount.toStringAsFixed(2),
      'method': method.apiValue,
      'reference': reference,
      'notes': notes,
    };
  }
}

class SupplierPayment {
  const SupplierPayment({
    required this.id,
    required this.supplierId,
    required this.supplierName,
    required this.amount,
    required this.method,
    this.purchaseOrderId,
    this.purchaseOrderNumber,
    this.reference = '',
    this.notes = '',
    this.paidAt,
    this.createdByUsername,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final int supplierId;
  final String supplierName;
  final int? purchaseOrderId;
  final String? purchaseOrderNumber;
  final double amount;
  final SupplierPaymentMethod method;
  final String reference;
  final String notes;
  final DateTime? paidAt;
  final String? createdByUsername;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory SupplierPayment.fromJson(Map<String, Object?> json) {
    return SupplierPayment(
      id: _intFromJson(json['id']),
      supplierId: _intFromJson(json['supplier']),
      supplierName: json['supplier_name']?.toString() ?? '',
      purchaseOrderId: _nullableIntFromJson(json['purchase_order']),
      purchaseOrderNumber: json['purchase_order_number']?.toString(),
      amount: _moneyFromJson(json['amount']),
      method: SupplierPaymentMethod.fromApiValue(json['method']),
      reference: json['reference']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      paidAt: _dateTimeFromJson(json['paid_at']),
      createdByUsername: json['created_by_username']?.toString(),
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class SupplierPaymentPage {
  const SupplierPaymentPage({required this.payments, required this.hasMore});

  final List<SupplierPayment> payments;
  final bool hasMore;

  factory SupplierPaymentPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(SupplierPayment.fromJson)
        .toList(growable: false);
    return SupplierPaymentPage(
      payments: results,
      hasMore: json['next'] != null,
    );
  }
}

const Object _unset = Object();

/// Purchase quantities arrive as 3dp decimal strings ("2.500"); parse
/// tolerantly like money.
double _quantityFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse((value ?? 0).toString()) ?? 0;
}

double? _nullableQuantityFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value.toString());
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

int? _nullableIntFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value.toString());
}

double _moneyFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

double? _nullableMoneyFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value.toString());
}

bool _boolFromJson(Object? value) {
  if (value is bool) {
    return value;
  }
  return value?.toString() == 'true';
}

List<Object?> _listFromJson(Object? value) {
  if (value is List<Object?>) {
    return value;
  }
  return const <Object?>[];
}

String _variantDisplayName(String? productName, String? variantName) {
  final product = productName?.trim() ?? '';
  final variant = variantName?.trim() ?? '';
  if (product.isEmpty) {
    return variant;
  }
  if (variant.isEmpty || variant == product) {
    return product;
  }
  return '$product - $variant';
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}

String _dateOnlyString(DateTime value) {
  return value.toIso8601String().split('T').first;
}

String _firstNonEmptyString(Iterable<Object?> values) {
  for (final value in values) {
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty) {
      return text;
    }
  }
  return '';
}
