import 'product_variant.dart';
import 'query.dart';

part 'purchase_submission_order.dart';
part 'purchase_submission_adjustments.dart';

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
  final double quantity;
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
    final quantity = _quantityFromJson(
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

/// Per-variant cost roll-up powering the product/variant detail cost metrics
/// and the "Change prices" dialog. Costs are derived from received purchase
/// history on the backend; any field can be null when a variant has never been
/// purchased.
class VariantCostSummary {
  const VariantCostSummary({
    required this.productId,
    required this.variantId,
    required this.variantName,
    required this.unitPrice,
    required this.purchasesCount,
    this.lowestCost,
    this.highestCost,
    this.lastCost,
    this.averageCost,
  });

  final int productId;
  final int variantId;
  final String variantName;
  final double unitPrice;
  final int purchasesCount;
  final double? lowestCost;
  final double? highestCost;
  final double? lastCost;
  final double? averageCost;

  bool get hasCost => purchasesCount > 0;

  factory VariantCostSummary.fromJson(Map<String, Object?> json) {
    return VariantCostSummary(
      productId: _intFromJson(json['product'] ?? json['product_id']),
      variantId: _intFromJson(json['variant'] ?? json['variant_id']),
      variantName: json['variant_name']?.toString() ?? '',
      unitPrice: _moneyFromJson(json['unit_price']),
      purchasesCount: _intFromJson(json['purchases_count']),
      lowestCost: _nullableMoneyFromJson(json['lowest_cost']),
      highestCost: _nullableMoneyFromJson(json['highest_cost']),
      lastCost: _nullableMoneyFromJson(json['last_cost']),
      averageCost: _nullableMoneyFromJson(json['average_cost']),
    );
  }

  static List<VariantCostSummary> listFromAny(Object? json) {
    final raw = json is Map<String, Object?>
        ? _listFromJson(json['results'] ?? json['variants'])
        : json;
    if (raw is! List<Object?>) {
      return const [];
    }
    return raw
        .whereType<Map<String, Object?>>()
        .map(VariantCostSummary.fromJson)
        .toList(growable: false);
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
    this.extraDiscountAmount = 0,
  });

  final List<PurchaseOrderLineDraft> lines;
  final int supplierId;
  final DateTime? dueDate;
  final String supplierInvoiceNumber;
  final DateTime? supplierInvoiceDate;
  final List<PurchaseLandedCostEntry> landedCostEntries;
  final LandedCostAllocationMethod landedCostAllocationMethod;
  final String discountCode;

  /// One-off order discount typed by hand (mostly a fraction eliminator).
  final double extraDiscountAmount;

  factory PurchaseOrderDraft.fromDraftLines(
    List<PurchaseDraftLine> lines, {
    required int supplierId,
    String supplierInvoiceNumber = '',
    DateTime? supplierInvoiceDate,
    List<PurchaseLandedCostEntry> landedCostEntries = const [],
    LandedCostAllocationMethod landedCostAllocationMethod =
        LandedCostAllocationMethod.byLineValue,
    String discountCode = '',
    double extraDiscountAmount = 0,
  }) {
    return PurchaseOrderDraft(
      supplierId: supplierId,
      supplierInvoiceNumber: supplierInvoiceNumber,
      supplierInvoiceDate: supplierInvoiceDate,
      landedCostEntries: landedCostEntries,
      landedCostAllocationMethod: landedCostAllocationMethod,
      discountCode: discountCode,
      extraDiscountAmount: extraDiscountAmount,
      lines: lines
          .map(
            (line) => PurchaseOrderLineDraft(
              variantId: line.variant.id,
              quantity: line.quantity,
              unitCost: line.unitCost,
              unit: line.unitCode,
              expiryDate: line.expiryDate,
            ),
          )
          .toList(growable: false),
    );
  }

  /// Serializes the draft for the API.
  ///
  /// For a create (`forUpdate: false`) the optional supplier-invoice and
  /// discount fields are omitted when blank — the backend already defaults them.
  /// For an edit (`forUpdate: true`) those editor-managed fields are *always*
  /// included (an empty string / empty list / null date) so that clearing them
  /// in the editor actually clears them on the draft, rather than silently
  /// keeping the old value. Lines and landed costs are replaced wholesale either
  /// way.
  Map<String, Object?> toJson({bool forUpdate = false}) {
    final invoiceNumber = supplierInvoiceNumber.trim();
    final normalizedDiscountCode = discountCode.trim();
    final invoiceDate = supplierInvoiceDate?.toIso8601String().split('T').first;
    return {
      'supplier': supplierId,
      if (dueDate != null)
        'due_date': dueDate!.toIso8601String().split('T').first,
      if (forUpdate || invoiceNumber.isNotEmpty)
        'supplier_invoice_number': invoiceNumber,
      if (forUpdate)
        'supplier_invoice_date': invoiceDate
      else if (invoiceDate != null)
        'supplier_invoice_date': invoiceDate,
      'landed_cost_entries': landedCostEntries
          .map((entry) => entry.toJson())
          .toList(growable: false),
      'landed_cost_allocation_method': landedCostAllocationMethod.apiValue,
      if (forUpdate || normalizedDiscountCode.isNotEmpty)
        'discount_codes': normalizedDiscountCode.isEmpty
            ? const <String>[]
            : [normalizedDiscountCode],
      if (forUpdate || extraDiscountAmount > 0)
        'extra_discount_amount': extraDiscountAmount.toStringAsFixed(2),
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
    this.extraDiscountAmount = 0,
  });

  final List<PurchaseOrderLineDraft> lines;
  final int supplierId;
  final List<PurchaseLandedCostEntry> landedCostEntries;
  final LandedCostAllocationMethod landedCostAllocationMethod;
  final String discountCode;
  final double extraDiscountAmount;

  factory PurchaseDiscountPreviewDraft.fromDraftLines(
    List<PurchaseDraftLine> lines, {
    required int supplierId,
    List<PurchaseLandedCostEntry> landedCostEntries = const [],
    LandedCostAllocationMethod landedCostAllocationMethod =
        LandedCostAllocationMethod.byLineValue,
    String discountCode = '',
    double extraDiscountAmount = 0,
  }) {
    return PurchaseDiscountPreviewDraft(
      supplierId: supplierId,
      landedCostEntries: landedCostEntries,
      landedCostAllocationMethod: landedCostAllocationMethod,
      discountCode: discountCode,
      extraDiscountAmount: extraDiscountAmount,
      lines: lines
          .map(
            (line) => PurchaseOrderLineDraft(
              variantId: line.variant.id,
              quantity: line.quantity,
              unitCost: line.unitCost,
              unit: line.unitCode,
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
      if (extraDiscountAmount > 0)
        'extra_discount_amount': extraDiscountAmount.toStringAsFixed(2),
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
  final double quantity;
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
      quantity: _quantityFromJson(json['quantity']),
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
    this.unitCode = '',
    this.unitLabel = '',
    this.unitFactor = 1,
    this.unitAllowsFractional = false,
    this.expiryDate,
  });

  final ProductVariant variant;

  /// In the purchase unit; fractional when [unitAllowsFractional] (2.5 kg,
  /// half an egg tray).
  final double quantity;
  final double unitCost;

  /// The purchase unit (a UnitOfMeasure.code); blank = the product's base unit.
  final String unitCode;
  final String unitLabel;

  /// Base units per one purchase unit, for showing the base equivalent.
  final double unitFactor;

  /// Whether this line's unit sells/buys in fractions — snapshotted from the
  /// unit so the quantity editor knows which keyboard to offer.
  final bool unitAllowsFractional;
  final DateTime? expiryDate;

  double get subtotal => unitCost * quantity;

  double get total => subtotal;

  bool get isBaseUnit => unitCode.isEmpty || unitFactor == 1;

  /// Quantity converted to the product's base unit.
  double get baseQuantity => quantity * unitFactor;

  PurchaseDraftLine copyWith({
    double? quantity,
    double? unitCost,
    String? unitCode,
    String? unitLabel,
    double? unitFactor,
    bool? unitAllowsFractional,
    DateTime? expiryDate,
    bool clearExpiryDate = false,
  }) {
    return PurchaseDraftLine(
      variant: variant,
      quantity: quantity ?? this.quantity,
      unitCost: unitCost ?? this.unitCost,
      unitCode: unitCode ?? this.unitCode,
      unitLabel: unitLabel ?? this.unitLabel,
      unitFactor: unitFactor ?? this.unitFactor,
      unitAllowsFractional: unitAllowsFractional ?? this.unitAllowsFractional,
      expiryDate: clearExpiryDate ? null : expiryDate ?? this.expiryDate,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'variant': variant.toCartJson(),
      'quantity': quantity,
      'unit_cost': unitCost,
      'unit_code': unitCode,
      'unit_label': unitLabel,
      'unit_factor': unitFactor,
      'unit_allows_fractional': unitAllowsFractional,
      'expiry_date': expiryDate?.toIso8601String(),
    };
  }

  factory PurchaseDraftLine.fromJson(Map<String, Object?> json) {
    final variantJson = json['variant'];
    if (variantJson is! Map<String, Object?>) {
      throw const FormatException('purchase draft line is missing its variant');
    }
    final expiry = json['expiry_date'];
    return PurchaseDraftLine(
      variant: ProductVariant.fromJson(variantJson),
      quantity: (json['quantity'] as num?)?.toDouble() ?? 0,
      unitCost: (json['unit_cost'] as num?)?.toDouble() ?? 0,
      unitCode: json['unit_code']?.toString() ?? '',
      unitLabel: json['unit_label']?.toString() ?? '',
      unitFactor: (json['unit_factor'] as num?)?.toDouble() ?? 1,
      unitAllowsFractional: json['unit_allows_fractional'] == true,
      expiryDate: expiry == null ? null : DateTime.tryParse(expiry.toString()),
    );
  }
}

class PurchaseOrderLineDraft {
  const PurchaseOrderLineDraft({
    required this.variantId,
    required this.quantity,
    required this.unitCost,
    this.unit = '',
    this.expiryDate,
  });

  final int variantId;
  final double quantity;
  final double unitCost;
  final String unit;
  final DateTime? expiryDate;

  Map<String, Object?> toJson() {
    final normalizedUnit = unit.trim();
    return {
      'variant': variantId,
      // Serialised as a 3dp string, matching the backend's decimal quantity.
      'quantity': quantity.toStringAsFixed(3),
      if (normalizedUnit.isNotEmpty) 'unit': normalizedUnit,
      'unit_cost': unitCost.toStringAsFixed(2),
      if (expiryDate != null) 'expiry_date': _dateOnlyString(expiryDate!),
    };
  }
}
