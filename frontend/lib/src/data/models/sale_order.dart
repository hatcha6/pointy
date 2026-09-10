import 'cart_line.dart';
import 'modifier_group.dart';
import 'print_job.dart';
import 'printer_config.dart';
import 'query.dart';

/// How a sale is recorded at checkout. `standard` is the normal paid-in-full
/// flow; `credit` (آجل) is a debt invoice issued unpaid or partly paid;
/// `quotation` (عرض سعر) is a non-binding price offer that moves no stock.
enum SaleType {
  standard('standard'),
  credit('credit'),
  quotation('quotation');

  const SaleType(this.apiValue);

  final String apiValue;

  static SaleType fromApiValue(Object? value) => switch (value?.toString()) {
    'credit' => SaleType.credit,
    'quotation' => SaleType.quotation,
    _ => SaleType.standard,
  };
}

/// How the till will get this sale's receipt to the customer.
///
/// The backend uses it to decide whether the sale needs a print-queue row at
/// all. [local] means this device prints the document itself and no agent
/// should ever see it.
enum ReceiptDelivery {
  local('local'),
  agent('agent');

  const ReceiptDelivery(this.apiValue);

  final String apiValue;
}

class SaleCheckoutDraft {
  const SaleCheckoutDraft({
    required this.lines,
    required this.payments,
    this.invoicePrinterConfig,
    this.customerId,
    this.couponCode = '',
    this.saleType = SaleType.standard,
    this.validUntil,
    this.dueDate,
    this.reserveStock = false,
    this.receiptDelivery,
  });

  final List<SaleCheckoutLineDraft> lines;
  final List<SaleCheckoutPaymentDraft> payments;
  final PrinterConfig? invoicePrinterConfig;
  final int? customerId;
  final String couponCode;
  final SaleType saleType;

  /// Quotation-only: how long the offer stands, and the bound on any stock hold.
  final DateTime? validUntil;

  /// Credit-only (آجل): when the debt is to be settled. Null on a credit sale
  /// is an instruction, not an omission — it leaves the tab open with no date,
  /// and is sent as an explicit null so the backend does not fill it in from
  /// the customer's standing terms.
  final DateTime? dueDate;

  /// Quotation-only: hold the quoted quantities until [validUntil].
  final bool reserveStock;

  /// Null from a caller that has not resolved its printer yet; the backend then
  /// falls back to whether any agent is reading the queue.
  final ReceiptDelivery? receiptDelivery;

  factory SaleCheckoutDraft.fromCart({
    required List<CartLine> cart,
    required List<SaleCheckoutPaymentDraft> payments,
    PrinterConfig? invoicePrinterConfig,
    int? customerId,
    String couponCode = '',
    SaleType saleType = SaleType.standard,
    DateTime? validUntil,
    DateTime? dueDate,
    bool reserveStock = false,
    ReceiptDelivery? receiptDelivery,
  }) {
    return SaleCheckoutDraft(
      lines: cart
          .map(
            (line) => SaleCheckoutLineDraft(
              variantId: line.variant.id,
              quantity: line.quantity,
              notes: line.notes,
              modifiers: line.modifiers,
              unit: line.unitCode,
            ),
          )
          .toList(growable: false),
      payments: payments,
      invoicePrinterConfig: invoicePrinterConfig,
      customerId: customerId,
      couponCode: couponCode,
      saleType: saleType,
      validUntil: validUntil,
      dueDate: dueDate,
      reserveStock: reserveStock,
      receiptDelivery: receiptDelivery,
    );
  }

  Map<String, Object?> toJson() {
    final normalizedCouponCode = couponCode.trim();
    return {
      'lines': lines.map((line) => line.toJson()).toList(growable: false),
      if (customerId != null) 'customer': customerId,
      if (normalizedCouponCode.isNotEmpty) 'coupon_code': normalizedCouponCode,
      'payments': payments.map((payment) => payment.toJson()).toList(),
      if (saleType != SaleType.standard) 'sale_type': saleType.apiValue,
      if (saleType == SaleType.quotation && validUntil != null)
        'valid_until': _apiDate(validUntil!),
      // Always sent for a credit sale, null included: the backend reads a
      // missing key as "apply the customer's terms" and a null one as "no due
      // date", and the till has already decided which it means.
      if (saleType == SaleType.credit)
        'due_date': dueDate == null ? null : _apiDate(dueDate!),
      if (reserveStock) 'reserve_stock': true,
      if (invoicePrinterConfig != null)
        'print_invoice': {
          'agent_id': invoicePrinterConfig!.agentId,
          'printer_endpoint': invoicePrinterConfig!.endpoint.toJson(),
        },
      // Tells the backend whether to make a queue row for this sale at all. A
      // driver/PDF printer is driven straight from here and never touches the
      // queue, so a row created for it is one nothing will ever read — in the
      // field that banked 24,264 unread receipt jobs while every receipt
      // printed fine. Saying so per sale also keeps a mixed shop honest: an
      // agent must not claim and re-print a receipt this till already produced.
      if (receiptDelivery != null)
        'receipt_delivery': receiptDelivery!.apiValue,
    };
  }
}

class SaleDiscountPreviewDraft {
  const SaleDiscountPreviewDraft({
    required this.lines,
    this.customerId,
    this.couponCode = '',
  });

  final List<SaleCheckoutLineDraft> lines;
  final int? customerId;
  final String couponCode;

  factory SaleDiscountPreviewDraft.fromCart({
    required List<CartLine> cart,
    int? customerId,
    String couponCode = '',
  }) {
    return SaleDiscountPreviewDraft(
      lines: cart
          .map(
            (line) => SaleCheckoutLineDraft(
              variantId: line.variant.id,
              quantity: line.quantity,
              // Modifiers and the unit affect price, so the discount preview must
              // carry them to return a total the cashier can trust. (Notes don't.)
              modifiers: line.modifiers,
              unit: line.unitCode,
            ),
          )
          .toList(growable: false),
      customerId: customerId,
      couponCode: couponCode,
    );
  }

  Map<String, Object?> toJson() {
    final normalizedCouponCode = couponCode.trim();
    return {
      'lines': lines.map((line) => line.toJson()).toList(growable: false),
      if (customerId != null) 'customer': customerId,
      if (normalizedCouponCode.isNotEmpty) 'coupon_code': normalizedCouponCode,
    };
  }
}

class SaleDiscountPreview {
  const SaleDiscountPreview({
    required this.subtotal,
    required this.discountTotal,
    required this.total,
    this.appliedDiscounts = const [],
    this.unappliedCouponCodes = const [],
    this.lossLines = const [],
    this.rulesActive = true,
    this.rulesVersion = '',
  });

  final double subtotal;
  final double discountTotal;
  final double total;
  final List<AppliedDiscountInfo> appliedDiscounts;
  final List<String> unappliedCouponCodes;
  final List<SaleLossLine> lossLines;

  /// Whether ANY sale discount rule is active shop-wide, and the discounts
  /// version that was true at. When false, the POS latches the version and
  /// computes previews locally until the server pushes a newer one — no
  /// request, no possible "تعذر تحديث الخصومات". The defaults keep old
  /// backends (which don't send these) on the live-preview path.
  final bool rulesActive;
  final String rulesVersion;

  factory SaleDiscountPreview.fromJson(Map<String, Object?> json) {
    return SaleDiscountPreview(
      subtotal: _moneyFromJson(json['subtotal']),
      discountTotal: _moneyFromJson(json['discount_total']),
      total: _moneyFromJson(json['total']),
      rulesActive: json['rules_active'] is bool
          ? json['rules_active'] as bool
          : true,
      rulesVersion: json['rules_version']?.toString() ?? '',
      appliedDiscounts: _listFromJson(json['applied_discounts'])
          .whereType<Map<String, Object?>>()
          .map(AppliedDiscountInfo.fromJson)
          .toList(growable: false),
      unappliedCouponCodes: _listFromJson(
        json['unapplied_coupon_codes'],
      ).map((code) => code.toString()).toList(growable: false),
      lossLines: _listFromJson(json['loss_lines'])
          .whereType<Map<String, Object?>>()
          .map(SaleLossLine.fromJson)
          .toList(growable: false),
    );
  }
}

class SaleLossLine {
  const SaleLossLine({
    required this.productName,
    required this.quantity,
    required this.unitPrice,
    required this.unitCost,
    required this.lineTotal,
    required this.lineCost,
    required this.lossAmount,
  });

  final String productName;
  final int quantity;
  final double unitPrice;
  final double unitCost;
  final double lineTotal;
  final double lineCost;
  final double lossAmount;

  factory SaleLossLine.fromJson(Map<String, Object?> json) {
    return SaleLossLine(
      productName:
          json['variant_name']?.toString() ??
          json['product_name']?.toString() ??
          '',
      quantity: _intFromJson(json['quantity']),
      unitPrice: _moneyFromJson(json['unit_price']),
      unitCost: _moneyFromJson(json['unit_cost']),
      lineTotal: _moneyFromJson(json['line_total']),
      lineCost: _moneyFromJson(json['line_cost']),
      lossAmount: _moneyFromJson(json['loss_amount']),
    );
  }
}

class AppliedDiscountInfo {
  const AppliedDiscountInfo({
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

  factory AppliedDiscountInfo.fromJson(Map<String, Object?> json) {
    return AppliedDiscountInfo(
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

class SaleCheckoutPaymentDraft {
  const SaleCheckoutPaymentDraft({
    required this.method,
    required this.amount,
    this.cardReceiptUrl = '',
  });

  final PaymentMethod method;
  final double amount;
  final String cardReceiptUrl;

  Map<String, Object?> toJson() {
    final normalizedReceiptUrl = cardReceiptUrl.trim();
    return {
      'method': method.apiValue,
      'amount': amount.toStringAsFixed(2),
      if (normalizedReceiptUrl.isNotEmpty)
        'card_receipt_url': normalizedReceiptUrl,
    };
  }
}

class SaleCheckoutLineDraft {
  const SaleCheckoutLineDraft({
    required this.variantId,
    required this.quantity,
    this.notes = '',
    this.modifiers = const [],
    this.unit = '',
  });

  final int variantId;
  final double quantity;
  final String notes;
  final List<CartLineModifier> modifiers;

  /// Selected unit code; blank = the product's base unit. The backend resolves
  /// the price and stock conversion from it.
  final String unit;

  Map<String, Object?> toJson() {
    final normalizedNotes = notes.trim();
    final normalizedUnit = unit.trim();
    return {
      'variant': variantId,
      'quantity': formatQuantityForApi(quantity),
      if (normalizedUnit.isNotEmpty) 'unit': normalizedUnit,
      if (normalizedNotes.isNotEmpty) 'notes': normalizedNotes,
      if (modifiers.isNotEmpty)
        'modifiers': modifiers
            .map((modifier) => modifier.toCheckoutJson())
            .toList(growable: false),
    };
  }
}

/// Whole quantities serialize as "2"; weights keep three places ("1.250").
String formatQuantityForApi(double quantity) {
  if (quantity == quantity.roundToDouble()) {
    return quantity.toStringAsFixed(0);
  }
  return quantity.toStringAsFixed(3);
}

class SaleOrder {
  const SaleOrder({
    required this.id,
    required this.status,
    this.docStatus = '',
    this.cancelledAt,
    this.cancelledByUsername,
    this.cancelReason,
    this.amendmentIndex = 0,
    required this.lines,
    required this.payments,
    required this.subtotal,
    required this.total,
    this.receiptNumber,
    this.registerSession,
    this.registerSessionNumber,
    this.customer,
    this.customerNumber,
    this.customerName,
    this.customerPhone,
    this.customerEmail,
    this.publicInvoiceUrl = '',
    this.profit,
    this.profitMarginPercent,
    this.invoicePrintJob,
    this.kitchenPrintJobs = const [],
    this.canVoid = false,
    this.canReturn = false,
    this.canExchange = false,
    this.canAssignCustomer = false,
    this.requiresManagerAdjustment = false,
    this.lineCount = 0,
    this.hasReturnableItems = false,
    this.discountTotal = 0,
    this.appliedDiscounts = const [],
    this.saleType = SaleType.standard,
    this.amountPaid = 0,
    this.balanceDue = 0,
    this.paymentStatus = '',
    this.validUntil,
    this.dueDate,
    this.isOverdue = false,
    this.daysOverdue = 0,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final String? receiptNumber;
  final String status;

  /// The document's own state — draft / submitted / cancelled — as against
  /// [status], which says where the money and the goods have got to. The two
  /// agree on the happy path and come apart exactly when something was undone.
  final String docStatus;
  final DateTime? cancelledAt;
  final String? cancelledByUsername;
  final String? cancelReason;
  final int amendmentIndex;
  final int? registerSession;
  final String? registerSessionNumber;
  final int? customer;
  final String? customerNumber;
  final String? customerName;
  final String? customerPhone;
  final String? customerEmail;
  final String publicInvoiceUrl;
  final double? profit;
  final double? profitMarginPercent;
  final PrintJob? invoicePrintJob;

  /// Kitchen chits queued for this sale (one per routed prep station). The
  /// device prints the ones it serves; the rest stay queued for other devices.
  final List<PrintJob> kitchenPrintJobs;
  final bool canVoid;
  final bool canReturn;
  final bool canExchange;

  /// Server-computed: an unpaid, non-void debt (credit) invoice may still be
  /// assigned to a different customer — nothing has been collected yet.
  final bool canAssignCustomer;
  final bool requiresManagerAdjustment;

  /// List/summary rows carry a line count and a returnable flag instead of the
  /// full line items (the detail fetch has those). Both fall back to deriving
  /// from [lines] when the full order is loaded.
  final int lineCount;
  final bool hasReturnableItems;
  final List<SaleOrderLine> lines;
  final List<SalePayment> payments;
  final double subtotal;
  final double discountTotal;
  final double total;
  final SaleType saleType;
  final double amountPaid;
  final double balanceDue;

  /// Server-computed: `paid` | `partial` | `unpaid` | `quotation`.
  final String paymentStatus;
  final DateTime? validUntil;

  /// Credit-only: when this debt is to be settled, and whether it is past that.
  /// [isOverdue] is derived server-side against the shop's local date and is
  /// never recomputed here — a till whose clock has drifted must not disagree
  /// with the reports about who is late.
  final DateTime? dueDate;
  final bool isOverdue;
  final int daysOverdue;

  final List<AppliedDiscountInfo> appliedDiscounts;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory SaleOrder.fromJson(Map<String, Object?> json) {
    final linesJson = (json['lines'] as List<Object?>?) ?? const [];
    final paymentsJson = (json['payments'] as List<Object?>?) ?? const [];
    final parsedLines = linesJson
        .whereType<Map<String, Object?>>()
        .map(SaleOrderLine.fromJson)
        .toList(growable: false);

    return SaleOrder(
      id: _intFromJson(json['id']),
      receiptNumber: json['receipt_number']?.toString(),
      status: json['status']?.toString() ?? '',
      docStatus: json['doc_status']?.toString() ?? '',
      cancelledAt: DateTime.tryParse(
        json['cancelled_at']?.toString() ?? '',
      )?.toLocal(),
      cancelledByUsername: json['cancelled_by_username']?.toString(),
      cancelReason: json['cancel_reason']?.toString(),
      amendmentIndex: (json['amendment_index'] as num?)?.toInt() ?? 0,
      registerSession: _nullableIntFromJson(json['register_session']),
      registerSessionNumber: json['register_session_number']?.toString(),
      customer: _nullableIntFromJson(json['customer']),
      customerNumber: json['customer_number']?.toString(),
      customerName: json['customer_name']?.toString(),
      customerPhone: json['customer_phone']?.toString(),
      customerEmail: json['customer_email']?.toString(),
      publicInvoiceUrl: json['public_invoice_url']?.toString() ?? '',
      profit: _nullableMoneyFromJson(
        json['profit'] ?? json['gross_profit'] ?? json['total_profit'],
      ),
      profitMarginPercent: _nullableMoneyFromJson(
        json['profit_margin_percent'] ?? json['gross_margin_percent'],
      ),
      invoicePrintJob: json['print_job'] is Map<String, Object?>
          ? PrintJob.fromJson(json['print_job'] as Map<String, Object?>)
          : null,
      kitchenPrintJobs:
          (json['kitchen_print_jobs'] as List<Object?>?)
              ?.whereType<Map<String, Object?>>()
              .map(PrintJob.fromJson)
              .toList(growable: false) ??
          const [],
      canVoid: _boolFromJson(json['can_void']),
      canReturn: _boolFromJson(json['can_return']),
      canExchange: _boolFromJson(json['can_exchange']),
      canAssignCustomer: _boolFromJson(json['can_assign_customer']),
      requiresManagerAdjustment: _boolFromJson(
        json['requires_manager_adjustment'],
      ),
      // List/summary rows send a count + returnable flag and omit the items;
      // the full detail response omits those, so fall back to the parsed lines.
      lineCount: (json['line_count'] as num?)?.toInt() ?? parsedLines.length,
      hasReturnableItems:
          json['has_returnable_items'] as bool? ??
          parsedLines.any((line) => line.returnableQuantity > 0),
      lines: parsedLines,
      payments: paymentsJson
          .whereType<Map<String, Object?>>()
          .map(SalePayment.fromJson)
          .toList(growable: false),
      subtotal: _moneyFromJson(json['subtotal']),
      discountTotal: _moneyFromJson(json['discount_total']),
      total: _moneyFromJson(json['total']),
      saleType: SaleType.fromApiValue(json['sale_type']),
      amountPaid: _moneyFromJson(json['amount_paid']),
      balanceDue: _moneyFromJson(json['balance_due']),
      paymentStatus: json['payment_status']?.toString() ?? '',
      validUntil: _dateTimeFromJson(json['valid_until']),
      dueDate: _dateTimeFromJson(json['due_date']),
      isOverdue: json['is_overdue'] == true,
      daysOverdue: (json['days_overdue'] as num?)?.toInt() ?? 0,
      appliedDiscounts: _listFromJson(json['applied_discounts'])
          .whereType<Map<String, Object?>>()
          .map(AppliedDiscountInfo.fromJson)
          .toList(growable: false),
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

enum PaymentMethod {
  cash('cash'),
  card('card'),
  transfer('transfer');

  const PaymentMethod(this.apiValue);

  final String apiValue;

  static PaymentMethod fromApiValue(Object? value) {
    return switch (value?.toString()) {
      'card' => PaymentMethod.card,
      'transfer' => PaymentMethod.transfer,
      _ => PaymentMethod.cash,
    };
  }
}

class SalePayment {
  const SalePayment({
    required this.id,
    required this.method,
    required this.amount,
    required this.commissionPercent,
    required this.commissionAmount,
    this.externalReference = '',
    this.cardReceipt,
    this.createdAt,
  });

  final int id;
  final PaymentMethod method;
  final double amount;
  final double commissionPercent;
  final double commissionAmount;
  final String externalReference;
  final SalePaymentCardReceipt? cardReceipt;
  final DateTime? createdAt;

  factory SalePayment.fromJson(Map<String, Object?> json) {
    return SalePayment(
      id: _intFromJson(json['id']),
      method: PaymentMethod.fromApiValue(json['method']),
      amount: _moneyFromJson(json['amount']),
      commissionPercent: _moneyFromJson(json['commission_percent']),
      commissionAmount: _moneyFromJson(json['commission_amount']),
      externalReference: json['external_reference']?.toString() ?? '',
      cardReceipt: json['card_receipt_data'] is Map<String, Object?>
          ? SalePaymentCardReceipt.fromJson(
              json['card_receipt_data'] as Map<String, Object?>,
            )
          : null,
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

class SalePaymentCardReceipt {
  const SalePaymentCardReceipt({
    required this.provider,
    required this.amount,
    required this.maskedPan,
    required this.rrn,
    required this.stan,
    required this.authorizationCode,
  });

  final String provider;
  final double amount;
  final String maskedPan;
  final String rrn;
  final String stan;
  final String authorizationCode;

  factory SalePaymentCardReceipt.fromJson(Map<String, Object?> json) {
    return SalePaymentCardReceipt(
      provider: json['provider']?.toString() ?? '',
      amount: _moneyFromJson(json['amount']),
      maskedPan: json['masked_pan']?.toString() ?? '',
      rrn: json['rrn']?.toString() ?? '',
      stan: json['stan']?.toString() ?? '',
      authorizationCode: json['authorization_code']?.toString() ?? '',
    );
  }
}

class SaleOrderLine {
  const SaleOrderLine({
    required this.id,
    required this.productId,
    required this.variantId,
    required this.quantity,
    required this.returnedQuantity,
    required this.returnableQuantity,
    this.unit = 'piece',
    this.unitLabel = '',
    required this.unitPrice,
    required this.total,
    this.productName,
    this.variantName,
    this.profit,
    this.subtotal = 0,
    this.discountTotal = 0,
  });

  final int id;
  final int productId;
  final int variantId;
  final String? productName;
  final String? variantName;
  final double quantity;
  final double returnedQuantity;
  final double returnableQuantity;
  final String unit;

  /// Short display label for [unit] (resolved by the backend).
  final String unitLabel;
  final double unitPrice;
  final double subtotal;
  final double discountTotal;
  final double total;
  final double? profit;

  factory SaleOrderLine.fromJson(Map<String, Object?> json) {
    return SaleOrderLine(
      id: _intFromJson(json['id']),
      productId: _productIdFromJson(json['product']),
      variantId: _productIdFromJson(json['variant']),
      productName: json['product_name']?.toString(),
      variantName: json['variant_name']?.toString(),
      quantity: _saleQuantityFromJson(json['quantity']),
      returnedQuantity: _saleQuantityFromJson(json['returned_quantity']),
      returnableQuantity: _saleQuantityFromJson(json['returnable_quantity']),
      unit: json['unit']?.toString() ?? 'piece',
      unitLabel: json['unit_label']?.toString() ?? '',
      unitPrice: _moneyFromJson(json['unit_price']),
      subtotal: _moneyFromJson(json['line_subtotal']),
      discountTotal: _moneyFromJson(json['discount_total']),
      total: _moneyFromJson(json['line_total'] ?? json['total']),
      profit: _nullableMoneyFromJson(
        json['profit'] ?? json['line_profit'] ?? json['gross_profit'],
      ),
    );
  }
}

enum SaleOrderStatusFilter implements QueryFilterSet {
  all(null),
  open(QueryFilter(parameter: 'status', value: 'open')),
  paid(QueryFilter(parameter: 'status', value: 'paid')),
  voided(QueryFilter(parameter: 'status', value: 'void'));

  const SaleOrderStatusFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum SaleOrderOrdering implements QueryOrdering {
  newest('-created_at'),
  updated('-updated_at'),
  totalDesc('-total'),
  receiptNumber('receipt_number');

  const SaleOrderOrdering(this.apiValue);

  @override
  final String apiValue;
}

class SaleOrderQuery extends ModelQuery {
  const SaleOrderQuery({
    this.search = '',
    this.status = SaleOrderStatusFilter.all,
    this.ordering = SaleOrderOrdering.newest,
    this.customerId,
    this.customerName,
    this.productId,
    this.variantId,
  });

  @override
  final String search;
  final SaleOrderStatusFilter status;
  final int? customerId;
  final String? customerName;
  final int? productId;
  final int? variantId;
  @override
  final SaleOrderOrdering ordering;

  bool get hasCustomerFilter => customerId != null;

  @override
  Iterable<QueryFilter> get filters => [
    ...status.filters,
    if (customerId != null)
      QueryFilter(parameter: 'customer', value: '$customerId'),
    if (productId != null)
      QueryFilter(parameter: 'product', value: '$productId'),
    if (variantId != null)
      QueryFilter(parameter: 'variant', value: '$variantId'),
  ];

  SaleOrderQuery withCustomer({int? id, String? name}) {
    return SaleOrderQuery(
      search: search,
      status: status,
      ordering: ordering,
      customerId: id,
      customerName: name,
      productId: productId,
      variantId: variantId,
    );
  }

  SaleOrderQuery copyWith({
    String? search,
    SaleOrderStatusFilter? status,
    SaleOrderOrdering? ordering,
    Object? customerId = _unset,
    Object? customerName = _unset,
    Object? productId = _unset,
    Object? variantId = _unset,
  }) {
    return SaleOrderQuery(
      search: search ?? this.search,
      status: status ?? this.status,
      ordering: ordering ?? this.ordering,
      customerId: identical(customerId, _unset)
          ? this.customerId
          : customerId as int?,
      customerName: identical(customerName, _unset)
          ? this.customerName
          : customerName as String?,
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
    return other is SaleOrderQuery &&
        other.search == search &&
        other.status == status &&
        other.ordering == ordering &&
        other.customerId == customerId &&
        other.customerName == customerName &&
        other.productId == productId &&
        other.variantId == variantId;
  }

  @override
  int get hashCode => Object.hash(
    search,
    status,
    ordering,
    customerId,
    customerName,
    productId,
    variantId,
  );
}

const Object _unset = Object();

class SaleVoidDraft {
  const SaleVoidDraft({this.reason = ''});

  final String reason;

  Map<String, Object?> toJson() {
    return {'reason': reason};
  }
}

class SaleReturnDraft {
  const SaleReturnDraft({required this.lines, this.reason = ''});

  final List<SaleReturnLineDraft> lines;
  final String reason;

  Map<String, Object?> toJson() {
    return {
      'reason': reason,
      'lines': lines.map((line) => line.toJson()).toList(growable: false),
    };
  }
}

class SaleReturnLineDraft {
  const SaleReturnLineDraft({required this.lineId, required this.quantity});

  final int lineId;
  final double quantity;

  Map<String, Object?> toJson() {
    return {'line': lineId, 'quantity': formatQuantityForApi(quantity)};
  }
}

/// A sales exchange: return the chosen original line(s) and ring up replacement
/// item(s) at current price. The backend settles only the net difference (see
/// `exchange_order_items`).
class SaleExchangeDraft {
  const SaleExchangeDraft({
    required this.lines,
    required this.replacementLines,
    this.settlementMethod = 'cash',
    this.reason = '',
  });

  /// Outbound (returned) lines — same shape as a return.
  final List<SaleReturnLineDraft> lines;
  final List<SaleExchangeReplacementLineDraft> replacementLines;

  /// Tender used to settle a positive difference owed by the customer.
  final String settlementMethod;
  final String reason;

  Map<String, Object?> toJson() {
    return {
      'reason': reason,
      'settlement_method': settlementMethod,
      'lines': lines.map((line) => line.toJson()).toList(growable: false),
      'replacement_lines': replacementLines
          .map((line) => line.toJson())
          .toList(growable: false),
    };
  }
}

class SaleExchangeReplacementLineDraft {
  const SaleExchangeReplacementLineDraft({
    required this.variantId,
    required this.quantity,
  });

  final int variantId;
  final double quantity;

  Map<String, Object?> toJson() {
    return {'variant': variantId, 'quantity': formatQuantityForApi(quantity)};
  }
}

/// A replacement product candidate surfaced by the exchange dialog's search.
class ExchangeProductOption {
  const ExchangeProductOption({
    required this.variantId,
    required this.label,
    required this.unitPrice,
    this.sku = '',
  });

  final int variantId;
  final String label;
  final double unitPrice;
  final String sku;
}

int _productIdFromJson(Object? value) {
  if (value is Map<String, Object?>) {
    return _intFromJson(value['id']);
  }
  return _intFromJson(value);
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  final normalized = (value ?? 0).toString();
  return int.tryParse(normalized) ?? double.tryParse(normalized)?.toInt() ?? 0;
}

int? _nullableIntFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  return int.tryParse(value.toString());
}

/// A calendar date as the API spells it. Dates crossing this boundary are
/// date-only on purpose: a due date is a day the shop agreed on, not an
/// instant, and sending a timestamp would let a timezone move it.
String _apiDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

double _moneyFromJson(Object? value) {
  return double.parse((value ?? 0).toString());
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

List<Object?> _listFromJson(Object? value) {
  if (value is List<Object?>) {
    return value;
  }
  return const [];
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

double _saleQuantityFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse((value ?? 0).toString()) ?? 0;
}
