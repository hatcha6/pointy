part of 'purchase_submission.dart';

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
    this.extraDiscountAmount = 0,
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
    this.currencyCode = '',
    this.exchangeRate,
    this.rateEffectiveAt,
    this.rateSource = '',
    this.foreignTotal,
    this.dueDate,
    this.paidTotal = 0,
    this.creditAppliedTotal = 0,
    this.adjustmentCreditTotal = 0,
    this.balanceDue = 0,
    this.paymentStatus = '',
    this.isOverdue = false,
    bool? isEditable,
    this.createdAt,
    this.submittedAt,
    this.receivedAt,
  }) : _isEditable = isEditable;

  final int id;
  final String orderNumber;

  /// The currency the SUPPLIER invoiced in; blank means the shop's own, which
  /// is every order that existed before this feature.
  ///
  /// Every money figure on this order — [subtotal], [total], [balanceDue], each
  /// line's [PurchaseOrderLine.unitCost] — stays in the shop's own currency
  /// regardless. What the currency adds is the number the buyer read off the
  /// invoice, plus the rate that turned it into dinars.
  final String currencyCode;

  /// The rate frozen on this order, and the instant it was effective. Frozen
  /// because a purchase order records what the shop actually paid: re-deriving
  /// its cost from today's rate would rewrite the margin on goods already sold.
  final double? exchangeRate;
  final DateTime? rateEffectiveAt;

  /// Where the rate came from — the feed, or a number the buyer typed.
  final String rateSource;

  /// The order total as the supplier invoiced it, for checking the screen
  /// against the paper invoice. Null for a base-currency order.
  final double? foreignTotal;

  bool get isForeignCurrency => currencyCode.isNotEmpty;

  bool get hasTypedRate => rateSource == 'manual';
  final String status;
  final int lineCount;
  final List<PurchaseOrderLine> lines;
  final List<PurchaseOrderAdjustment> adjustments;
  final List<PurchaseReceipt> receipts;
  final double subtotal;
  final double discountTotal;

  /// The one-off manual discount included in [discountTotal].
  final double extraDiscountAmount;
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

  /// What the server said about editability, when it said anything. Older
  /// backends omit the field; [isEditable] falls back to the same rule they
  /// enforce.
  final bool? _isEditable;

  /// An order can be reopened and edited until money settles against it —
  /// receiving does not close it, a payment or credit does, and so does a
  /// return (whose lines hang off the receipt an edit would replace). Decided
  /// server-side by purchasing.services.purchase_order_is_editable; the
  /// fallback is the older rule, for an app talking to a backend that predates
  /// the field.
  bool get isEditable =>
      _isEditable ??
      (status == 'draft' ||
          (status == 'submitted' && paymentStatus == 'unpaid'));

  /// Whether editing this order will re-record a delivery that is already on
  /// the shelf — what the editor warns about before it opens.
  bool get hasReceivedStock =>
      status == 'received' ||
      status == 'partially_received' ||
      status == 'partial';

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
      currencyCode: json['currency']?.toString() ?? '',
      exchangeRate: _nullableMoneyFromJson(json['exchange_rate']),
      rateEffectiveAt: _dateTimeFromJson(json['rate_effective_at']),
      rateSource: json['rate_source']?.toString() ?? '',
      foreignTotal: _nullableMoneyFromJson(json['foreign_total']),
      // The list/payables rows carry a `line_count` and omit the line items
      // (the detail screen re-fetches the full order); the full detail response
      // has no `line_count`, so fall back to the parsed lines.
      lineCount: (json['line_count'] as num?)?.toInt() ?? lines.length,
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
      extraDiscountAmount: _moneyFromJson(json['extra_discount_amount']),
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
      isEditable: json['is_editable'] == null
          ? null
          : _boolFromJson(json['is_editable']),
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
    this.unit = '',
    this.unitLabel = '',
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
    this.unitCostInCurrency,
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
  final double quantity;
  final double adjustedQuantity;
  final double adjustableQuantity;
  final double receivedQuantity;
  final double damagedQuantity;
  final double rejectedQuantity;
  final double openQuantity;
  final bool hasReceivingTotals;
  final double unitCost;

  /// Purchase unit code and its short display label (resolved by the backend).
  final String unit;
  final String unitLabel;
  final double discountAmount;
  final double? netLineTotal;
  final double? netUnitCost;
  final double total;
  final double? previousUnitCost;
  final double? unitCostChange;
  final double? unitCostChangePercent;

  /// What the supplier's invoice says for one of this unit, in the ORDER's
  /// currency. Null on a base-currency order. [unitCost] above is always the
  /// shop's own currency and is derived from this at the order's frozen rate,
  /// so the two can never disagree.
  final double? unitCostInCurrency;
  final double? landedCostAllocation;
  final double? landedUnitCost;
  final double? effectiveUnitCost;
  final double? landedLineTotal;

  double get receivableQuantity => openQuantity < 0 ? 0 : openQuantity;

  double get varianceQuantity => receivedQuantity + damagedQuantity - quantity;

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
    final receivedQuantity = _nullableQuantityFromJson(
      json['accepted_quantity'] ??
          json['quantity_accepted'] ??
          json['received_quantity'] ??
          json['quantity_received'] ??
          json['received_total'] ??
          json['total_received'],
    );
    final damagedQuantity = _nullableQuantityFromJson(
      json['damaged_quantity'] ??
          json['quantity_damaged'] ??
          json['damaged_total'] ??
          json['total_damaged'],
    );
    final rejectedQuantity = _nullableQuantityFromJson(
      json['rejected_quantity'] ??
          json['cancelled_quantity'] ??
          json['quantity_rejected'] ??
          json['quantity_cancelled'] ??
          json['rejected_total'] ??
          json['cancelled_total'] ??
          json['total_rejected'],
    );
    final openQuantity = _nullableQuantityFromJson(
      json['open_quantity'] ??
          json['remaining_quantity'] ??
          json['backordered_quantity'] ??
          json['quantity_open'] ??
          json['quantity_remaining'],
    );
    final quantity = _quantityFromJson(json['quantity']);
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
      adjustedQuantity: _quantityFromJson(json['adjusted_quantity']),
      adjustableQuantity: _quantityFromJson(json['adjustable_quantity']),
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
      unit: json['unit']?.toString() ?? '',
      unitLabel: json['unit_label']?.toString() ?? '',
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
      unitCostInCurrency: _nullableMoneyFromJson(json['unit_cost_in_currency']),
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
    double? receivedQuantity,
    double? damagedQuantity,
    double? rejectedQuantity,
    double? openQuantity,
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
      unit: unit,
      unitLabel: unitLabel,
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
  final double quantityReceived;
  final double quantityDamaged;
  final double quantityRejected;
  final DateTime? expiryDate;

  Map<String, Object?> toJson() {
    return {
      'purchase_line': purchaseLineId,
      // 3dp strings, matching the backend's decimal quantities.
      'quantity_received': quantityReceived.toStringAsFixed(3),
      'quantity_damaged': quantityDamaged.toStringAsFixed(3),
      if (quantityRejected > 0)
        'quantity_rejected': quantityRejected.toStringAsFixed(3),
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
  final double quantityReceived;
  final double quantityDamaged;
  final double quantityRejected;
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
      quantityReceived: _quantityFromJson(
        json['accepted_quantity'] ??
            json['quantity_accepted'] ??
            json['quantity_received'] ??
            json['received_quantity'],
      ),
      quantityDamaged: _quantityFromJson(
        json['quantity_damaged'] ?? json['damaged_quantity'],
      ),
      quantityRejected: _quantityFromJson(
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
