import 'product.dart';
import 'query.dart';

class PurchaseSubmission {
  const PurchaseSubmission({
    required this.draftNumber,
    required this.lineCount,
    required this.total,
    required this.status,
  });

  final String draftNumber;
  final int lineCount;
  final double total;
  final String status;
}

enum PurchaseOrderStatusFilter implements QueryFilterSet {
  all(null),
  draft(QueryFilter(parameter: 'status', value: 'draft')),
  submitted(QueryFilter(parameter: 'status', value: 'submitted')),
  received(QueryFilter(parameter: 'status', value: 'received')),
  cancelled(QueryFilter(parameter: 'status', value: 'cancelled'));

  const PurchaseOrderStatusFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum PurchaseOrderOrdering implements QueryOrdering {
  newest('-created_at'),
  updated('-updated_at'),
  totalDesc('-total'),
  orderNumber('order_number');

  const PurchaseOrderOrdering(this.apiValue);

  @override
  final String apiValue;
}

class PurchaseOrderQuery extends ModelQuery {
  const PurchaseOrderQuery({
    this.search = '',
    this.status = PurchaseOrderStatusFilter.all,
    this.ordering = PurchaseOrderOrdering.newest,
    this.supplierId,
    this.supplierName,
  });

  @override
  final String search;
  final PurchaseOrderStatusFilter status;
  final int? supplierId;
  final String? supplierName;
  @override
  final PurchaseOrderOrdering ordering;

  @override
  Iterable<QueryFilter> get filters => [
    ...status.filters,
    if (supplierId != null)
      QueryFilter(parameter: 'supplier', value: '$supplierId'),
  ];

  PurchaseOrderQuery copyWith({
    String? search,
    PurchaseOrderStatusFilter? status,
    PurchaseOrderOrdering? ordering,
    Object? supplierId = _unset,
    Object? supplierName = _unset,
  }) {
    return PurchaseOrderQuery(
      search: search ?? this.search,
      status: status ?? this.status,
      ordering: ordering ?? this.ordering,
      supplierId: identical(supplierId, _unset)
          ? this.supplierId
          : supplierId as int?,
      supplierName: identical(supplierName, _unset)
          ? this.supplierName
          : supplierName as String?,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PurchaseOrderQuery &&
        other.search == search &&
        other.status == status &&
        other.ordering == ordering &&
        other.supplierId == supplierId &&
        other.supplierName == supplierName;
  }

  @override
  int get hashCode =>
      Object.hash(search, status, ordering, supplierId, supplierName);
}

class PurchaseOrderPage {
  const PurchaseOrderPage({required this.orders, required this.hasMore});

  final List<PurchaseOrder> orders;
  final bool hasMore;

  factory PurchaseOrderPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(PurchaseOrder.fromJson)
        .toList(growable: false);

    return PurchaseOrderPage(orders: results, hasMore: json['next'] != null);
  }
}

class PurchaseOrderDraft {
  const PurchaseOrderDraft({
    required this.lines,
    required this.supplierId,
    this.dueDate,
    this.supplierInvoiceNumber = '',
    this.supplierInvoiceDate,
  });

  final List<PurchaseOrderLineDraft> lines;
  final int supplierId;
  final DateTime? dueDate;
  final String supplierInvoiceNumber;
  final DateTime? supplierInvoiceDate;

  factory PurchaseOrderDraft.fromDraftLines(
    List<PurchaseDraftLine> lines, {
    required int supplierId,
    String supplierInvoiceNumber = '',
    DateTime? supplierInvoiceDate,
  }) {
    return PurchaseOrderDraft(
      supplierId: supplierId,
      supplierInvoiceNumber: supplierInvoiceNumber,
      supplierInvoiceDate: supplierInvoiceDate,
      lines: lines
          .map(
            (line) => PurchaseOrderLineDraft(
              productId: line.product.id,
              quantity: line.quantity,
              unitCost: line.unitCost,
            ),
          )
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() {
    final invoiceNumber = supplierInvoiceNumber.trim();
    return {
      'supplier': supplierId,
      if (dueDate != null)
        'due_date': dueDate!.toIso8601String().split('T').first,
      if (invoiceNumber.isNotEmpty) 'supplier_invoice_number': invoiceNumber,
      if (supplierInvoiceDate != null)
        'supplier_invoice_date': supplierInvoiceDate!
            .toIso8601String()
            .split('T')
            .first,
      'lines': lines.map((line) => line.toJson()).toList(),
    };
  }
}

class PurchaseDraftLine {
  const PurchaseDraftLine({
    required this.product,
    required this.quantity,
    required this.unitCost,
  });

  final Product product;
  final int quantity;
  final double unitCost;

  double get subtotal => unitCost * quantity;

  double get total => subtotal;

  PurchaseDraftLine copyWith({int? quantity, double? unitCost}) {
    return PurchaseDraftLine(
      product: product,
      quantity: quantity ?? this.quantity,
      unitCost: unitCost ?? this.unitCost,
    );
  }
}

class PurchaseOrderLineDraft {
  const PurchaseOrderLineDraft({
    required this.productId,
    required this.quantity,
    required this.unitCost,
  });

  final int productId;
  final int quantity;
  final double unitCost;

  Map<String, Object?> toJson() {
    return {
      'product': productId,
      'quantity': quantity,
      'unit_cost': unitCost.toStringAsFixed(2),
    };
  }
}

class PurchaseOrder {
  const PurchaseOrder({
    required this.id,
    required this.orderNumber,
    required this.status,
    required this.lineCount,
    required this.total,
    required this.lines,
    required this.adjustments,
    required this.receipts,
    required this.subtotal,
    required this.canReturn,
    required this.canRefund,
    required this.canExchange,
    this.supplierId,
    this.supplierName,
    this.supplierInvoiceNumber = '',
    this.supplierInvoiceDate,
    this.dueDate,
    this.paidTotal = 0,
    this.creditAppliedTotal = 0,
    this.adjustmentCreditTotal = 0,
    this.balanceDue = 0,
    this.paymentStatus = '',
    this.isOverdue = false,
    this.createdAt,
    this.submittedAt,
    this.receivedAt,
  });

  final int id;
  final String orderNumber;
  final String status;
  final int lineCount;
  final List<PurchaseOrderLine> lines;
  final List<PurchaseOrderAdjustment> adjustments;
  final List<PurchaseReceipt> receipts;
  final double subtotal;
  final double total;
  final bool canReturn;
  final bool canRefund;
  final bool canExchange;
  final int? supplierId;
  final String? supplierName;
  final String supplierInvoiceNumber;
  final DateTime? supplierInvoiceDate;
  final DateTime? dueDate;
  final double paidTotal;
  final double creditAppliedTotal;
  final double adjustmentCreditTotal;
  final double balanceDue;
  final String paymentStatus;
  final bool isOverdue;
  final DateTime? createdAt;
  final DateTime? submittedAt;
  final DateTime? receivedAt;

  bool get hasOpenReceiving =>
      lines.any((line) => line.openQuantity > 0 || line.receivableQuantity > 0);

  factory PurchaseOrder.fromJson(Map<String, Object?> json) {
    final rawLines = json['lines'] is List<Object?>
        ? json['lines'] as List<Object?>
        : const <Object?>[];
    final adjustments = json['adjustments'] is List<Object?>
        ? json['adjustments'] as List<Object?>
        : const <Object?>[];
    final rawReceipts = _listFromJson(
      json['receipts'] ??
          json['receipt_history'] ??
          json['receive_history'] ??
          json['receiving_history'],
    );
    final status = json['status']?.toString() ?? '';
    final parsedLines = rawLines
        .whereType<Map<String, Object?>>()
        .map(PurchaseOrderLine.fromJson)
        .toList(growable: false);
    final lines =
        status == 'received' &&
            parsedLines.isNotEmpty &&
            parsedLines.every((line) => !line.hasReceivingTotals)
        ? parsedLines
              .map(
                (line) => line.copyWith(
                  receivedQuantity: line.quantity,
                  openQuantity: 0,
                ),
              )
              .toList(growable: false)
        : parsedLines;
    return PurchaseOrder(
      id: _intFromJson(json['id']),
      orderNumber: json['order_number']?.toString() ?? '',
      status: status,
      supplierId: _nullableIntFromJson(json['supplier']),
      supplierName: json['supplier_name']?.toString(),
      supplierInvoiceNumber: _firstNonEmptyString([
        json['supplier_invoice_number'],
        json['supplier_reference'],
      ]),
      supplierInvoiceDate: _dateTimeFromJson(json['supplier_invoice_date']),
      lineCount: lines.length,
      lines: lines,
      adjustments: adjustments
          .whereType<Map<String, Object?>>()
          .map(PurchaseOrderAdjustment.fromJson)
          .toList(growable: false),
      receipts: rawReceipts
          .whereType<Map<String, Object?>>()
          .map(PurchaseReceipt.fromJson)
          .toList(growable: false),
      subtotal: _moneyFromJson(json['subtotal']),
      total: _moneyFromJson(json['total']),
      canReturn: _boolFromJson(json['can_return']),
      canRefund: _boolFromJson(json['can_refund']),
      canExchange: _boolFromJson(json['can_exchange']),
      dueDate: _dateTimeFromJson(json['due_date']),
      paidTotal: _moneyFromJson(json['paid_total']),
      creditAppliedTotal: _moneyFromJson(json['credit_applied_total']),
      adjustmentCreditTotal: _moneyFromJson(json['adjustment_credit_total']),
      balanceDue: _moneyFromJson(json['balance_due']),
      paymentStatus: json['payment_status']?.toString() ?? '',
      isOverdue: _boolFromJson(json['is_overdue']),
      createdAt: _dateTimeFromJson(json['created_at']),
      submittedAt: _dateTimeFromJson(json['submitted_at']),
      receivedAt: _dateTimeFromJson(json['received_at']),
    );
  }

  PurchaseSubmission toSubmission() {
    return PurchaseSubmission(
      draftNumber: orderNumber,
      lineCount: lineCount,
      total: total,
      status: status,
    );
  }
}

class PurchaseOrderLine {
  const PurchaseOrderLine({
    required this.id,
    required this.productId,
    required this.quantity,
    required this.adjustedQuantity,
    required this.adjustableQuantity,
    required this.receivedQuantity,
    required this.damagedQuantity,
    required this.rejectedQuantity,
    required this.openQuantity,
    required this.hasReceivingTotals,
    required this.unitCost,
    required this.total,
    this.productName,
    this.productSku,
    this.previousUnitCost,
    this.unitCostChange,
    this.unitCostChangePercent,
  });

  final int id;
  final int productId;
  final String? productName;
  final String? productSku;
  final int quantity;
  final int adjustedQuantity;
  final int adjustableQuantity;
  final int receivedQuantity;
  final int damagedQuantity;
  final int rejectedQuantity;
  final int openQuantity;
  final bool hasReceivingTotals;
  final double unitCost;
  final double total;
  final double? previousUnitCost;
  final double? unitCostChange;
  final double? unitCostChangePercent;

  int get receivableQuantity => openQuantity < 0 ? 0 : openQuantity;

  int get varianceQuantity => receivedQuantity + damagedQuantity - quantity;

  double? get effectiveUnitCostChange {
    final explicitChange = unitCostChange;
    if (explicitChange != null) {
      return explicitChange;
    }
    final previousCost = previousUnitCost;
    if (previousCost == null) {
      return null;
    }
    return unitCost - previousCost;
  }

  factory PurchaseOrderLine.fromJson(Map<String, Object?> json) {
    final previousUnitCost = _nullableMoneyFromJson(
      json['previous_unit_cost'] ??
          json['last_unit_cost'] ??
          json['previous_cost'] ??
          json['last_cost'],
    );
    final receivedQuantity = _nullableIntFromJson(
      json['accepted_quantity'] ??
          json['quantity_accepted'] ??
          json['received_quantity'] ??
          json['quantity_received'] ??
          json['received_total'] ??
          json['total_received'],
    );
    final damagedQuantity = _nullableIntFromJson(
      json['damaged_quantity'] ??
          json['quantity_damaged'] ??
          json['damaged_total'] ??
          json['total_damaged'],
    );
    final rejectedQuantity = _nullableIntFromJson(
      json['rejected_quantity'] ??
          json['cancelled_quantity'] ??
          json['quantity_rejected'] ??
          json['quantity_cancelled'] ??
          json['rejected_total'] ??
          json['cancelled_total'] ??
          json['total_rejected'],
    );
    final openQuantity = _nullableIntFromJson(
      json['open_quantity'] ??
          json['remaining_quantity'] ??
          json['backordered_quantity'] ??
          json['quantity_open'] ??
          json['quantity_remaining'],
    );
    final quantity = _intFromJson(json['quantity']);
    return PurchaseOrderLine(
      id: _intFromJson(json['id']),
      productId: _intFromJson(json['product']),
      productName: json['product_name']?.toString(),
      productSku: json['product_sku']?.toString(),
      quantity: quantity,
      adjustedQuantity: _intFromJson(json['adjusted_quantity']),
      adjustableQuantity: _intFromJson(json['adjustable_quantity']),
      receivedQuantity: receivedQuantity ?? 0,
      damagedQuantity: damagedQuantity ?? 0,
      rejectedQuantity: rejectedQuantity ?? 0,
      openQuantity:
          openQuantity ??
          (quantity -
              (receivedQuantity ?? 0) -
              (damagedQuantity ?? 0) -
              (rejectedQuantity ?? 0)),
      hasReceivingTotals:
          receivedQuantity != null ||
          damagedQuantity != null ||
          rejectedQuantity != null ||
          openQuantity != null,
      unitCost: _moneyFromJson(json['unit_cost']),
      total: _moneyFromJson(json['line_total']),
      previousUnitCost: previousUnitCost,
      unitCostChange: _nullableMoneyFromJson(
        json['unit_cost_change'] ??
            json['cost_change'] ??
            json['unit_cost_delta'] ??
            json['cost_delta'],
      ),
      unitCostChangePercent: _nullableMoneyFromJson(
        json['unit_cost_change_percent'] ??
            json['cost_change_percent'] ??
            json['cost_delta_percent'],
      ),
    );
  }

  PurchaseOrderLine copyWith({
    int? receivedQuantity,
    int? damagedQuantity,
    int? rejectedQuantity,
    int? openQuantity,
    bool? hasReceivingTotals,
  }) {
    return PurchaseOrderLine(
      id: id,
      productId: productId,
      productName: productName,
      productSku: productSku,
      quantity: quantity,
      adjustedQuantity: adjustedQuantity,
      adjustableQuantity: adjustableQuantity,
      receivedQuantity: receivedQuantity ?? this.receivedQuantity,
      damagedQuantity: damagedQuantity ?? this.damagedQuantity,
      rejectedQuantity: rejectedQuantity ?? this.rejectedQuantity,
      openQuantity: openQuantity ?? this.openQuantity,
      hasReceivingTotals: hasReceivingTotals ?? this.hasReceivingTotals,
      unitCost: unitCost,
      total: total,
      previousUnitCost: previousUnitCost,
      unitCostChange: unitCostChange,
      unitCostChangePercent: unitCostChangePercent,
    );
  }
}

class PurchaseReceiveDraft {
  const PurchaseReceiveDraft({required this.lines, this.note = ''});

  final List<PurchaseReceiveLineDraft> lines;
  final String note;

  Map<String, Object?> toJson() {
    return {
      'lines': lines.map((line) => line.toJson()).toList(growable: false),
      if (note.trim().isNotEmpty) 'note': note.trim(),
    };
  }
}

class PurchaseReceiveLineDraft {
  const PurchaseReceiveLineDraft({
    required this.purchaseLineId,
    required this.quantityReceived,
    required this.quantityDamaged,
    this.quantityRejected = 0,
  });

  final int purchaseLineId;
  final int quantityReceived;
  final int quantityDamaged;
  final int quantityRejected;

  Map<String, Object?> toJson() {
    return {
      'purchase_line': purchaseLineId,
      'quantity_received': quantityReceived,
      'quantity_damaged': quantityDamaged,
      if (quantityRejected > 0) 'quantity_rejected': quantityRejected,
    };
  }
}

class PurchaseReceipt {
  const PurchaseReceipt({
    required this.id,
    required this.lines,
    this.note = '',
    this.createdByUsername,
    this.createdAt,
  });

  final int id;
  final List<PurchaseReceiptLine> lines;
  final String note;
  final String? createdByUsername;
  final DateTime? createdAt;

  factory PurchaseReceipt.fromJson(Map<String, Object?> json) {
    final lines = _listFromJson(json['lines']);
    return PurchaseReceipt(
      id: _intFromJson(json['id']),
      lines: lines
          .whereType<Map<String, Object?>>()
          .map(PurchaseReceiptLine.fromJson)
          .toList(growable: false),
      note: json['note']?.toString() ?? json['notes']?.toString() ?? '',
      createdByUsername: json['created_by_username']?.toString(),
      createdAt: _dateTimeFromJson(
        json['received_at'] ?? json['created_at'] ?? json['timestamp'],
      ),
    );
  }
}

class PurchaseReceiptLine {
  const PurchaseReceiptLine({
    required this.purchaseLineId,
    required this.quantityReceived,
    required this.quantityDamaged,
    required this.quantityRejected,
    this.productName,
  });

  final int purchaseLineId;
  final int quantityReceived;
  final int quantityDamaged;
  final int quantityRejected;
  final String? productName;

  factory PurchaseReceiptLine.fromJson(Map<String, Object?> json) {
    return PurchaseReceiptLine(
      purchaseLineId: _intFromJson(json['purchase_line'] ?? json['line']),
      quantityReceived: _intFromJson(
        json['accepted_quantity'] ??
            json['quantity_accepted'] ??
            json['quantity_received'] ??
            json['received_quantity'],
      ),
      quantityDamaged: _intFromJson(
        json['quantity_damaged'] ?? json['damaged_quantity'],
      ),
      quantityRejected: _intFromJson(
        json['quantity_rejected'] ??
            json['rejected_quantity'] ??
            json['cancelled_quantity'] ??
            json['quantity_cancelled'],
      ),
      productName: json['product_name']?.toString(),
    );
  }
}

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
      credits: credits
          .whereType<Map<String, Object?>>()
          .map(SupplierCredit.fromJson)
          .toList(growable: false),
      createdAt: _dateTimeFromJson(json['created_at']),
    );
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
    required this.quantity,
    required this.unitCost,
    required this.total,
    this.productName,
  });

  final int id;
  final int purchaseLineId;
  final int productId;
  final String? productName;
  final int quantity;
  final double unitCost;
  final double total;

  factory PurchaseOrderAdjustmentLine.fromJson(Map<String, Object?> json) {
    return PurchaseOrderAdjustmentLine(
      id: _intFromJson(json['id']),
      purchaseLineId: _intFromJson(json['purchase_line']),
      productId: _intFromJson(json['product']),
      productName: json['product_name']?.toString(),
      quantity: _intFromJson(json['quantity']),
      unitCost: _moneyFromJson(json['unit_cost']),
      total: _moneyFromJson(json['line_total']),
    );
  }
}

class PurchaseAdjustmentDraft {
  const PurchaseAdjustmentDraft({required this.lines, this.reason = ''});

  final List<PurchaseAdjustmentLineDraft> lines;
  final String reason;

  Map<String, Object?> toJson() {
    return {
      'reason': reason,
      'lines': lines.map((line) => line.toJson()).toList(growable: false),
    };
  }
}

class PurchaseAdjustmentLineDraft {
  const PurchaseAdjustmentLineDraft({
    required this.lineId,
    required this.quantity,
  });

  final int lineId;
  final int quantity;

  Map<String, Object?> toJson() {
    return {'line': lineId, 'quantity': quantity};
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

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
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
