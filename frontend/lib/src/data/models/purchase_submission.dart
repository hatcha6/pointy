import 'product_variant.dart';
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
    this.productId,
    this.variantId,
  });

  @override
  final String search;
  final PurchaseOrderStatusFilter status;
  final int? supplierId;
  final String? supplierName;
  final int? productId;
  final int? variantId;
  @override
  final PurchaseOrderOrdering ordering;

  @override
  Iterable<QueryFilter> get filters => [
    ...status.filters,
    if (supplierId != null)
      QueryFilter(parameter: 'supplier', value: '$supplierId'),
    if (productId != null)
      QueryFilter(parameter: 'product', value: '$productId'),
    if (variantId != null)
      QueryFilter(parameter: 'variant', value: '$variantId'),
  ];

  PurchaseOrderQuery copyWith({
    String? search,
    PurchaseOrderStatusFilter? status,
    PurchaseOrderOrdering? ordering,
    Object? supplierId = _unset,
    Object? supplierName = _unset,
    Object? productId = _unset,
    Object? variantId = _unset,
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
      productId: identical(productId, _unset)
          ? this.productId
          : productId as int?,
      variantId: identical(variantId, _unset)
          ? this.variantId
          : variantId as int?,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PurchaseOrderQuery &&
        other.search == search &&
        other.status == status &&
        other.ordering == ordering &&
        other.supplierId == supplierId &&
        other.supplierName == supplierName &&
        other.productId == productId &&
        other.variantId == variantId;
  }

  @override
  int get hashCode => Object.hash(
    search,
    status,
    ordering,
    supplierId,
    supplierName,
    productId,
    variantId,
  );
}

class PurchaseOrderPage {
  const PurchaseOrderPage({required this.orders, required this.hasMore});

  final List<PurchaseOrder> orders;
  final bool hasMore;

  factory PurchaseOrderPage.fromJson(Map<String, Object?> json) {
    final results = _listFromJson(json['results'])
        .whereType<Map<String, Object?>>()
        .map(PurchaseOrder.fromJson)
        .toList(growable: false);

    return PurchaseOrderPage(orders: results, hasMore: json['next'] != null);
  }

  factory PurchaseOrderPage.fromAny(Object? json) {
    if (json is List<Object?>) {
      return PurchaseOrderPage(
        orders: json
            .whereType<Map<String, Object?>>()
            .map(PurchaseOrder.fromJson)
            .toList(growable: false),
        hasMore: false,
      );
    }
    if (json is Map<String, Object?>) {
      if (json['results'] is List<Object?>) {
        return PurchaseOrderPage.fromJson(json);
      }
      final orders = _listFromJson(
        json['orders'] ?? json['purchase_orders'] ?? json['history'],
      );
      return PurchaseOrderPage(
        orders: orders
            .whereType<Map<String, Object?>>()
            .map(PurchaseOrder.fromJson)
            .toList(growable: false),
        hasMore: json['next'] != null,
      );
    }
    return const PurchaseOrderPage(orders: [], hasMore: false);
  }
}

class ProductCostHistoryEntry {
  const ProductCostHistoryEntry({
    required this.productId,
    required this.variantId,
    required this.unitCost,
    required this.quantity,
    required this.total,
    this.variantName,
    this.purchaseOrderId,
    this.purchaseOrderNumber,
    this.supplierId,
    this.supplierName,
    this.effectiveUnitCost,
    this.landedUnitCost,
    this.recordedAt,
  });

  final int productId;
  final int variantId;
  final String? variantName;
  final int? purchaseOrderId;
  final String? purchaseOrderNumber;
  final int? supplierId;
  final String? supplierName;
  final int quantity;
  final double unitCost;
  final double? effectiveUnitCost;
  final double? landedUnitCost;
  final double total;
  final DateTime? recordedAt;

  factory ProductCostHistoryEntry.fromJson(Map<String, Object?> json) {
    final unitCost = _moneyFromJson(
      json['unit_cost'] ?? json['latest_unit_cost'] ?? json['cost'],
    );
    final effectiveUnitCost = _nullableMoneyFromJson(
      json['effective_unit_cost'] ??
          json['landed_unit_cost'] ??
          json['unit_cost_with_landed_cost'],
    );
    final quantity = _intFromJson(
      json['quantity'] ?? json['received_quantity'],
    );
    return ProductCostHistoryEntry(
      productId: _intFromJson(json['product'] ?? json['product_id']),
      variantId: _intFromJson(json['variant'] ?? json['variant_id']),
      variantName: json['variant_name']?.toString(),
      purchaseOrderId: _nullableIntFromJson(
        json['purchase_order'] ?? json['purchase_order_id'] ?? json['order'],
      ),
      purchaseOrderNumber:
          json['purchase_order_number']?.toString() ??
          json['order_number']?.toString(),
      supplierId: _nullableIntFromJson(json['supplier'] ?? json['supplier_id']),
      supplierName: json['supplier_name']?.toString(),
      quantity: quantity,
      unitCost: unitCost,
      effectiveUnitCost: effectiveUnitCost,
      landedUnitCost: _nullableMoneyFromJson(json['landed_unit_cost']),
      total:
          _nullableMoneyFromJson(json['total'] ?? json['line_total']) ??
          unitCost * quantity,
      recordedAt: _dateTimeFromJson(
        json['received_at'] ??
            json['supplier_invoice_date'] ??
            json['created_at'] ??
            json['date'],
      ),
    );
  }
}

class ProductCostHistoryPage {
  const ProductCostHistoryPage({required this.entries, required this.hasMore});

  final List<ProductCostHistoryEntry> entries;
  final bool hasMore;

  factory ProductCostHistoryPage.fromAny(Object? json) {
    if (json is List<Object?>) {
      return ProductCostHistoryPage(
        entries: json
            .whereType<Map<String, Object?>>()
            .map(ProductCostHistoryEntry.fromJson)
            .toList(growable: false),
        hasMore: false,
      );
    }
    if (json is Map<String, Object?>) {
      final rawEntries = _listFromJson(
        json['results'] ?? json['history'] ?? json['entries'],
      );
      return ProductCostHistoryPage(
        entries: rawEntries
            .whereType<Map<String, Object?>>()
            .map(ProductCostHistoryEntry.fromJson)
            .toList(growable: false),
        hasMore: json['next'] != null,
      );
    }
    return const ProductCostHistoryPage(entries: [], hasMore: false);
  }
}

class ProductMarginImpact {
  const ProductMarginImpact({
    required this.productId,
    required this.unitPrice,
    this.latestUnitCost,
    this.latestEffectiveUnitCost,
    this.grossProfit,
    this.marginPercent,
    this.previousUnitCost,
    this.costChange,
    this.marginChangePercent,
  });

  final int productId;
  final double unitPrice;
  final double? latestUnitCost;
  final double? latestEffectiveUnitCost;
  final double? grossProfit;
  final double? marginPercent;
  final double? previousUnitCost;
  final double? costChange;
  final double? marginChangePercent;

  factory ProductMarginImpact.fromJson(Map<String, Object?> json) {
    return ProductMarginImpact(
      productId: _intFromJson(json['product'] ?? json['product_id']),
      unitPrice: _moneyFromJson(json['unit_price']),
      latestUnitCost: _nullableMoneyFromJson(
        json['latest_unit_cost'] ?? json['unit_cost'] ?? json['latest_cost'],
      ),
      latestEffectiveUnitCost: _nullableMoneyFromJson(
        json['latest_effective_unit_cost'] ??
            json['effective_unit_cost'] ??
            json['landed_unit_cost'] ??
            json['unit_cost_with_landed_cost'],
      ),
      grossProfit: _nullableMoneyFromJson(
        json['gross_profit'] ??
            json['profit'] ??
            json['margin_amount'] ??
            json['latest_margin_amount'],
      ),
      marginPercent: _nullableMoneyFromJson(
        json['margin_percent'] ??
            json['gross_margin_percent'] ??
            json['margin_percentage'] ??
            json['latest_margin_percent'],
      ),
      previousUnitCost: _nullableMoneyFromJson(
        json['previous_unit_cost'] ?? json['previous_cost'],
      ),
      costChange: _nullableMoneyFromJson(
        json['cost_change'] ??
            json['unit_cost_change'] ??
            json['cost_delta'] ??
            json['unit_cost_delta'] ??
            json['effective_unit_cost_delta'],
      ),
      marginChangePercent: _nullableMoneyFromJson(
        json['margin_change_percent'] ??
            json['margin_delta_percent'] ??
            json['margin_percent_delta'],
      ),
    );
  }
}

enum LandedCostAllocationMethod {
  byLineValue('line_value'),
  byQuantity('quantity'),
  byRetailValue('retail_value'),
  equallyByLine('equal');

  const LandedCostAllocationMethod(this.apiValue);

  final String apiValue;

  static LandedCostAllocationMethod fromApiValue(Object? value) {
    return switch (value?.toString()) {
      'quantity' => LandedCostAllocationMethod.byQuantity,
      'retail_value' => LandedCostAllocationMethod.byRetailValue,
      'equal' => LandedCostAllocationMethod.equallyByLine,
      _ => LandedCostAllocationMethod.byLineValue,
    };
  }
}

class PurchaseLandedCostEntry {
  const PurchaseLandedCostEntry({
    required this.name,
    required this.cost,
    this.id,
  });

  final int? id;
  final String name;
  final double cost;

  Map<String, Object?> toJson() {
    return {'name': name.trim(), 'amount': cost.toStringAsFixed(2)};
  }

  factory PurchaseLandedCostEntry.fromJson(Map<String, Object?> json) {
    return PurchaseLandedCostEntry(
      id: _nullableIntFromJson(json['id']),
      name: json['name']?.toString() ?? '',
      cost: _moneyFromJson(json['amount'] ?? json['cost']),
    );
  }
}

class PurchaseOrderDraft {
  const PurchaseOrderDraft({
    required this.lines,
    required this.supplierId,
    this.dueDate,
    this.supplierInvoiceNumber = '',
    this.supplierInvoiceDate,
    this.landedCostEntries = const [],
    this.landedCostAllocationMethod = LandedCostAllocationMethod.byLineValue,
    this.discountCode = '',
  });

  final List<PurchaseOrderLineDraft> lines;
  final int supplierId;
  final DateTime? dueDate;
  final String supplierInvoiceNumber;
  final DateTime? supplierInvoiceDate;
  final List<PurchaseLandedCostEntry> landedCostEntries;
  final LandedCostAllocationMethod landedCostAllocationMethod;
  final String discountCode;

  factory PurchaseOrderDraft.fromDraftLines(
    List<PurchaseDraftLine> lines, {
    required int supplierId,
    String supplierInvoiceNumber = '',
    DateTime? supplierInvoiceDate,
    List<PurchaseLandedCostEntry> landedCostEntries = const [],
    LandedCostAllocationMethod landedCostAllocationMethod =
        LandedCostAllocationMethod.byLineValue,
    String discountCode = '',
  }) {
    return PurchaseOrderDraft(
      supplierId: supplierId,
      supplierInvoiceNumber: supplierInvoiceNumber,
      supplierInvoiceDate: supplierInvoiceDate,
      landedCostEntries: landedCostEntries,
      landedCostAllocationMethod: landedCostAllocationMethod,
      discountCode: discountCode,
      lines: lines
          .map(
            (line) => PurchaseOrderLineDraft(
              variantId: line.variant.id,
              quantity: line.quantity,
              unitCost: line.unitCost,
              expiryDate: line.expiryDate,
            ),
          )
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() {
    final invoiceNumber = supplierInvoiceNumber.trim();
    final normalizedDiscountCode = discountCode.trim();
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
      'landed_cost_entries': landedCostEntries
          .map((entry) => entry.toJson())
          .toList(growable: false),
      'landed_cost_allocation_method': landedCostAllocationMethod.apiValue,
      if (normalizedDiscountCode.isNotEmpty)
        'discount_codes': [normalizedDiscountCode],
      'lines': lines.map((line) => line.toJson()).toList(),
    };
  }
}

class PurchaseDiscountPreviewDraft {
  const PurchaseDiscountPreviewDraft({
    required this.lines,
    required this.supplierId,
    this.landedCostEntries = const [],
    this.landedCostAllocationMethod = LandedCostAllocationMethod.byLineValue,
    this.discountCode = '',
  });

  final List<PurchaseOrderLineDraft> lines;
  final int supplierId;
  final List<PurchaseLandedCostEntry> landedCostEntries;
  final LandedCostAllocationMethod landedCostAllocationMethod;
  final String discountCode;

  factory PurchaseDiscountPreviewDraft.fromDraftLines(
    List<PurchaseDraftLine> lines, {
    required int supplierId,
    List<PurchaseLandedCostEntry> landedCostEntries = const [],
    LandedCostAllocationMethod landedCostAllocationMethod =
        LandedCostAllocationMethod.byLineValue,
    String discountCode = '',
  }) {
    return PurchaseDiscountPreviewDraft(
      supplierId: supplierId,
      landedCostEntries: landedCostEntries,
      landedCostAllocationMethod: landedCostAllocationMethod,
      discountCode: discountCode,
      lines: lines
          .map(
            (line) => PurchaseOrderLineDraft(
              variantId: line.variant.id,
              quantity: line.quantity,
              unitCost: line.unitCost,
            ),
          )
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() {
    final normalizedDiscountCode = discountCode.trim();
    return {
      'supplier': supplierId,
      'landed_cost_entries': landedCostEntries
          .map((entry) => entry.toJson())
          .toList(growable: false),
      'landed_cost_allocation_method': landedCostAllocationMethod.apiValue,
      if (normalizedDiscountCode.isNotEmpty)
        'discount_codes': [normalizedDiscountCode],
      'lines': lines.map((line) => line.toJson()).toList(),
    };
  }
}

class PurchaseDiscountPreview {
  const PurchaseDiscountPreview({
    required this.subtotal,
    required this.discountTotal,
    required this.landedCostTotal,
    required this.total,
    this.lines = const [],
    this.appliedDiscounts = const [],
    this.unappliedDiscountCodes = const [],
  });

  final double subtotal;
  final double discountTotal;
  final double landedCostTotal;
  final double total;
  final List<PurchaseDiscountPreviewLine> lines;
  final List<AppliedPurchaseDiscount> appliedDiscounts;
  final List<String> unappliedDiscountCodes;

  factory PurchaseDiscountPreview.fromJson(Map<String, Object?> json) {
    return PurchaseDiscountPreview(
      subtotal: _moneyFromJson(json['subtotal']),
      discountTotal: _moneyFromJson(json['discount_total']),
      landedCostTotal: _moneyFromJson(json['landed_cost_total']),
      total: _moneyFromJson(json['total']),
      lines: _listFromJson(json['lines'])
          .whereType<Map<String, Object?>>()
          .map(PurchaseDiscountPreviewLine.fromJson)
          .toList(growable: false),
      appliedDiscounts: _listFromJson(json['applied_discounts'])
          .whereType<Map<String, Object?>>()
          .map(AppliedPurchaseDiscount.fromJson)
          .toList(growable: false),
      unappliedDiscountCodes: _listFromJson(
        json['unapplied_discount_codes'],
      ).map((code) => code.toString()).toList(growable: false),
    );
  }
}

class PurchaseDiscountPreviewLine {
  const PurchaseDiscountPreviewLine({
    required this.productId,
    required this.variantId,
    required this.quantity,
    required this.unitCost,
    required this.lineTotal,
    this.productName,
    this.variantName,
    this.variantSku,
    this.discountAmount = 0,
    this.netLineTotal,
    this.netUnitCost,
    this.allocatedLandedCost = 0,
    this.landedUnitCost = 0,
    this.effectiveUnitCost,
    this.effectiveLineTotal,
  });

  final int productId;
  final int variantId;
  final String? productName;
  final String? variantName;
  final String? variantSku;
  final int quantity;
  final double unitCost;
  final double lineTotal;
  final double discountAmount;
  final double? netLineTotal;
  final double? netUnitCost;
  final double allocatedLandedCost;
  final double landedUnitCost;
  final double? effectiveUnitCost;
  final double? effectiveLineTotal;

  factory PurchaseDiscountPreviewLine.fromJson(Map<String, Object?> json) {
    return PurchaseDiscountPreviewLine(
      productId: _intFromJson(json['product'] ?? json['product_id']),
      variantId: _intFromJson(
        json['variant'] ?? json['variant_id'] ?? json['product'],
      ),
      productName: json['product_name']?.toString(),
      variantName: json['variant_name']?.toString(),
      variantSku: json['variant_sku']?.toString(),
      quantity: _intFromJson(json['quantity']),
      unitCost: _moneyFromJson(json['unit_cost']),
      lineTotal: _moneyFromJson(json['line_total']),
      discountAmount: _moneyFromJson(json['discount_amount']),
      netLineTotal: _nullableMoneyFromJson(json['net_line_total']),
      netUnitCost: _nullableMoneyFromJson(json['net_unit_cost']),
      allocatedLandedCost: _moneyFromJson(
        json['allocated_landed_cost'] ??
            json['landed_cost_allocation'] ??
            json['landed_cost'],
      ),
      landedUnitCost: _moneyFromJson(json['landed_unit_cost']),
      effectiveUnitCost: _nullableMoneyFromJson(
        json['effective_unit_cost'] ?? json['unit_cost_with_landed_cost'],
      ),
      effectiveLineTotal: _nullableMoneyFromJson(
        json['effective_line_total'] ??
            json['landed_line_total'] ??
            json['line_total_with_landed_cost'],
      ),
    );
  }
}

class PurchaseDraftLine {
  const PurchaseDraftLine({
    required this.variant,
    required this.quantity,
    required this.unitCost,
    this.expiryDate,
  });

  final ProductVariant variant;
  final int quantity;
  final double unitCost;
  final DateTime? expiryDate;

  double get subtotal => unitCost * quantity;

  double get total => subtotal;

  PurchaseDraftLine copyWith({
    int? quantity,
    double? unitCost,
    DateTime? expiryDate,
    bool clearExpiryDate = false,
  }) {
    return PurchaseDraftLine(
      variant: variant,
      quantity: quantity ?? this.quantity,
      unitCost: unitCost ?? this.unitCost,
      expiryDate: clearExpiryDate ? null : expiryDate ?? this.expiryDate,
    );
  }
}

class PurchaseOrderLineDraft {
  const PurchaseOrderLineDraft({
    required this.variantId,
    required this.quantity,
    required this.unitCost,
    this.expiryDate,
  });

  final int variantId;
  final int quantity;
  final double unitCost;
  final DateTime? expiryDate;

  Map<String, Object?> toJson() {
    return {
      'variant': variantId,
      'quantity': quantity,
      'unit_cost': unitCost.toStringAsFixed(2),
      if (expiryDate != null) 'expiry_date': _dateOnlyString(expiryDate!),
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
    this.discountTotal = 0,
    this.discountCodes = const [],
    this.appliedDiscounts = const [],
    this.landedCostEntries = const [],
    this.landedCostTotal = 0,
    this.landedCostAllocationMethod = LandedCostAllocationMethod.byLineValue,
    this.supplierId,
    this.supplierName,
    this.supplierContactName,
    this.supplierPhone,
    this.supplierEmail,
    this.supplierAddress,
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
  final double discountTotal;
  final List<String> discountCodes;
  final List<AppliedPurchaseDiscount> appliedDiscounts;
  final double total;
  final List<PurchaseLandedCostEntry> landedCostEntries;
  final double landedCostTotal;
  final LandedCostAllocationMethod landedCostAllocationMethod;
  final bool canReturn;
  final bool canRefund;
  final bool canExchange;
  final int? supplierId;
  final String? supplierName;
  final String? supplierContactName;
  final String? supplierPhone;
  final String? supplierEmail;
  final String? supplierAddress;
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
    final landedCostEntries = _listFromJson(json['landed_cost_entries'])
        .whereType<Map<String, Object?>>()
        .map(PurchaseLandedCostEntry.fromJson)
        .toList(growable: false);
    final entryLandedCostTotal = landedCostEntries.fold<double>(
      0,
      (sum, entry) => sum + entry.cost,
    );
    return PurchaseOrder(
      id: _intFromJson(json['id']),
      orderNumber: json['order_number']?.toString() ?? '',
      status: status,
      supplierId: _nullableIntFromJson(json['supplier']),
      supplierName: json['supplier_name']?.toString(),
      supplierContactName: json['supplier_contact_name']?.toString(),
      supplierPhone: json['supplier_phone']?.toString(),
      supplierEmail: json['supplier_email']?.toString(),
      supplierAddress: json['supplier_address']?.toString(),
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
      discountTotal: _moneyFromJson(json['discount_total']),
      discountCodes: _listFromJson(
        json['discount_codes'],
      ).map((code) => code.toString()).toList(growable: false),
      appliedDiscounts: _listFromJson(json['applied_discounts'])
          .whereType<Map<String, Object?>>()
          .map(AppliedPurchaseDiscount.fromJson)
          .toList(growable: false),
      total: _moneyFromJson(json['total']),
      landedCostEntries: landedCostEntries,
      landedCostTotal:
          _nullableMoneyFromJson(json['landed_cost_total']) ??
          entryLandedCostTotal,
      landedCostAllocationMethod: LandedCostAllocationMethod.fromApiValue(
        json['landed_cost_allocation_method'],
      ),
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

class AppliedPurchaseDiscount {
  const AppliedPurchaseDiscount({
    required this.ruleName,
    required this.source,
    required this.scope,
    required this.valueType,
    required this.discountAmount,
    this.couponCode = '',
    this.roundingMode = '',
    this.roundingIncrement,
    this.unroundedDiscountAmount,
    this.roundingAdjustment,
  });

  final String ruleName;
  final String couponCode;
  final String source;
  final String scope;
  final String valueType;
  final double discountAmount;
  final String roundingMode;
  final double? roundingIncrement;
  final double? unroundedDiscountAmount;
  final double? roundingAdjustment;

  factory AppliedPurchaseDiscount.fromJson(Map<String, Object?> json) {
    return AppliedPurchaseDiscount(
      ruleName: json['rule_name']?.toString() ?? '',
      couponCode: json['coupon_code']?.toString() ?? '',
      source: json['source']?.toString() ?? '',
      scope: json['scope']?.toString() ?? '',
      valueType: json['value_type']?.toString() ?? '',
      discountAmount: _moneyFromJson(json['discount_amount']),
      roundingMode: json['rounding_mode']?.toString() ?? '',
      roundingIncrement: _nullableMoneyFromJson(json['rounding_increment']),
      unroundedDiscountAmount: _nullableMoneyFromJson(
        json['unrounded_discount_amount'],
      ),
      roundingAdjustment: _nullableMoneyFromJson(json['rounding_adjustment']),
    );
  }
}

class PurchaseOrderLine {
  const PurchaseOrderLine({
    required this.id,
    required this.productId,
    required this.variantId,
    required this.quantity,
    required this.adjustedQuantity,
    required this.adjustableQuantity,
    required this.receivedQuantity,
    required this.damagedQuantity,
    required this.rejectedQuantity,
    required this.openQuantity,
    required this.hasReceivingTotals,
    required this.unitCost,
    this.discountAmount = 0,
    this.netLineTotal,
    this.netUnitCost,
    required this.total,
    this.productName,
    this.variantName,
    this.variantSku,
    this.tracksExpiry = false,
    this.expiryDate,
    this.previousUnitCost,
    this.unitCostChange,
    this.unitCostChangePercent,
    this.landedCostAllocation,
    this.landedUnitCost,
    this.effectiveUnitCost,
    this.landedLineTotal,
  });

  final int id;
  final int productId;
  final int variantId;
  final String? productName;
  final String? variantName;
  final String? variantSku;
  final bool tracksExpiry;
  final DateTime? expiryDate;
  final int quantity;
  final int adjustedQuantity;
  final int adjustableQuantity;
  final int receivedQuantity;
  final int damagedQuantity;
  final int rejectedQuantity;
  final int openQuantity;
  final bool hasReceivingTotals;
  final double unitCost;
  final double discountAmount;
  final double? netLineTotal;
  final double? netUnitCost;
  final double total;
  final double? previousUnitCost;
  final double? unitCostChange;
  final double? unitCostChangePercent;
  final double? landedCostAllocation;
  final double? landedUnitCost;
  final double? effectiveUnitCost;
  final double? landedLineTotal;

  int get receivableQuantity => openQuantity < 0 ? 0 : openQuantity;

  int get varianceQuantity => receivedQuantity + damagedQuantity - quantity;

  String get displayName => _variantDisplayName(productName, variantName);

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
      variantId: _intFromJson(
        json['variant'] ?? json['variant_id'] ?? json['product'],
      ),
      productName: json['product_name']?.toString(),
      variantName: json['variant_name']?.toString(),
      variantSku: json['variant_sku']?.toString(),
      tracksExpiry: _boolFromJson(json['tracks_expiry']),
      expiryDate: _dateTimeFromJson(json['expiry_date']),
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
      discountAmount: _moneyFromJson(json['discount_amount']),
      netLineTotal: _nullableMoneyFromJson(json['net_line_total']),
      netUnitCost: _nullableMoneyFromJson(json['net_unit_cost']),
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
      landedCostAllocation: _nullableMoneyFromJson(
        json['landed_cost_allocation'] ??
            json['allocated_landed_cost'] ??
            json['landed_cost'],
      ),
      landedUnitCost: _nullableMoneyFromJson(json['landed_unit_cost']),
      effectiveUnitCost: _nullableMoneyFromJson(
        json['effective_unit_cost'] ?? json['unit_cost_with_landed_cost'],
      ),
      landedLineTotal: _nullableMoneyFromJson(
        json['landed_line_total'] ??
            json['line_total_with_landed_cost'] ??
            json['effective_line_total'],
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
      variantId: variantId,
      productName: productName,
      variantName: variantName,
      variantSku: variantSku,
      tracksExpiry: tracksExpiry,
      expiryDate: expiryDate,
      quantity: quantity,
      adjustedQuantity: adjustedQuantity,
      adjustableQuantity: adjustableQuantity,
      receivedQuantity: receivedQuantity ?? this.receivedQuantity,
      damagedQuantity: damagedQuantity ?? this.damagedQuantity,
      rejectedQuantity: rejectedQuantity ?? this.rejectedQuantity,
      openQuantity: openQuantity ?? this.openQuantity,
      hasReceivingTotals: hasReceivingTotals ?? this.hasReceivingTotals,
      unitCost: unitCost,
      discountAmount: discountAmount,
      netLineTotal: netLineTotal,
      netUnitCost: netUnitCost,
      total: total,
      previousUnitCost: previousUnitCost,
      unitCostChange: unitCostChange,
      unitCostChangePercent: unitCostChangePercent,
      landedCostAllocation: landedCostAllocation,
      landedUnitCost: landedUnitCost,
      effectiveUnitCost: effectiveUnitCost,
      landedLineTotal: landedLineTotal,
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
    this.expiryDate,
  });

  final int purchaseLineId;
  final int quantityReceived;
  final int quantityDamaged;
  final int quantityRejected;
  final DateTime? expiryDate;

  Map<String, Object?> toJson() {
    return {
      'purchase_line': purchaseLineId,
      'quantity_received': quantityReceived,
      'quantity_damaged': quantityDamaged,
      if (quantityRejected > 0) 'quantity_rejected': quantityRejected,
      if (expiryDate != null) 'expiry_date': _dateOnlyString(expiryDate!),
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
    required this.productId,
    required this.variantId,
    required this.quantityReceived,
    required this.quantityDamaged,
    required this.quantityRejected,
    this.productName,
    this.variantName,
    this.variantSku,
    this.expiryDate,
  });

  final int purchaseLineId;
  final int productId;
  final int variantId;
  final int quantityReceived;
  final int quantityDamaged;
  final int quantityRejected;
  final String? productName;
  final String? variantName;
  final String? variantSku;
  final DateTime? expiryDate;

  String get displayName => _variantDisplayName(productName, variantName);

  factory PurchaseReceiptLine.fromJson(Map<String, Object?> json) {
    return PurchaseReceiptLine(
      purchaseLineId: _intFromJson(json['purchase_line'] ?? json['line']),
      productId: _intFromJson(json['product'] ?? json['product_id']),
      variantId: _intFromJson(
        json['variant'] ?? json['variant_id'] ?? json['product'],
      ),
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
      variantName: json['variant_name']?.toString(),
      variantSku: json['variant_sku']?.toString(),
      expiryDate: _dateTimeFromJson(json['expiry_date']),
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
  final int quantity;
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
      quantity: _intFromJson(json['quantity']),
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
  final int quantity;
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
      quantity: _intFromJson(json['quantity']),
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
  final int quantity;

  Map<String, Object?> toJson() {
    return {'line': lineId, 'quantity': quantity};
  }
}

class PurchaseReplacementLineDraft {
  const PurchaseReplacementLineDraft({
    required this.variantId,
    required this.quantity,
    required this.unitCost,
  });

  final int variantId;
  final int quantity;
  final double unitCost;

  Map<String, Object?> toJson() {
    return {
      'variant': variantId,
      'quantity': quantity,
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
