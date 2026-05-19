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
  const PurchaseOrderDraft({required this.lines, this.supplierId});

  final List<PurchaseOrderLineDraft> lines;
  final int? supplierId;

  factory PurchaseOrderDraft.fromDraftLines(
    List<PurchaseDraftLine> lines, {
    int? supplierId,
  }) {
    return PurchaseOrderDraft(
      supplierId: supplierId,
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
    return {
      if (supplierId != null) 'supplier': supplierId,
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
    required this.subtotal,
    required this.canReturn,
    required this.canRefund,
    required this.canExchange,
    this.supplierName,
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
  final double subtotal;
  final double total;
  final bool canReturn;
  final bool canRefund;
  final bool canExchange;
  final String? supplierName;
  final DateTime? createdAt;
  final DateTime? submittedAt;
  final DateTime? receivedAt;

  factory PurchaseOrder.fromJson(Map<String, Object?> json) {
    final lines = json['lines'] is List<Object?>
        ? json['lines'] as List<Object?>
        : const <Object?>[];
    final adjustments = json['adjustments'] is List<Object?>
        ? json['adjustments'] as List<Object?>
        : const <Object?>[];
    return PurchaseOrder(
      id: _intFromJson(json['id']),
      orderNumber: json['order_number']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      supplierName: json['supplier_name']?.toString(),
      lineCount: lines.length,
      lines: lines
          .whereType<Map<String, Object?>>()
          .map(PurchaseOrderLine.fromJson)
          .toList(growable: false),
      adjustments: adjustments
          .whereType<Map<String, Object?>>()
          .map(PurchaseOrderAdjustment.fromJson)
          .toList(growable: false),
      subtotal: _moneyFromJson(json['subtotal']),
      total: _moneyFromJson(json['total']),
      canReturn: _boolFromJson(json['can_return']),
      canRefund: _boolFromJson(json['can_refund']),
      canExchange: _boolFromJson(json['can_exchange']),
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
  final double unitCost;
  final double total;
  final double? previousUnitCost;
  final double? unitCostChange;
  final double? unitCostChangePercent;

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
    return PurchaseOrderLine(
      id: _intFromJson(json['id']),
      productId: _intFromJson(json['product']),
      productName: json['product_name']?.toString(),
      productSku: json['product_sku']?.toString(),
      quantity: _intFromJson(json['quantity']),
      adjustedQuantity: _intFromJson(json['adjusted_quantity']),
      adjustableQuantity: _intFromJson(json['adjustable_quantity']),
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
    this.reason = '',
    this.createdByUsername,
    this.createdAt,
  });

  final int id;
  final PurchaseAdjustmentType type;
  final double amount;
  final String reason;
  final String? createdByUsername;
  final List<PurchaseOrderAdjustmentLine> lines;
  final DateTime? createdAt;

  factory PurchaseOrderAdjustment.fromJson(Map<String, Object?> json) {
    final lines = json['lines'] is List<Object?>
        ? json['lines'] as List<Object?>
        : const <Object?>[];
    return PurchaseOrderAdjustment(
      id: _intFromJson(json['id']),
      type: PurchaseAdjustmentType.fromApiValue(json['adjustment_type']),
      amount: _moneyFromJson(json['amount']),
      reason: json['reason']?.toString() ?? '',
      createdByUsername: json['created_by_username']?.toString(),
      lines: lines
          .whereType<Map<String, Object?>>()
          .map(PurchaseOrderAdjustmentLine.fromJson)
          .toList(growable: false),
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

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
