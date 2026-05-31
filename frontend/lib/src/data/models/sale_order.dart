import 'cart_line.dart';
import 'print_job.dart';
import 'printer_config.dart';

class SaleCheckoutDraft {
  const SaleCheckoutDraft({
    required this.lines,
    required this.payments,
    this.invoicePrinterConfig,
    this.customerId,
    this.couponCode = '',
  });

  final List<SaleCheckoutLineDraft> lines;
  final List<SaleCheckoutPaymentDraft> payments;
  final PrinterConfig? invoicePrinterConfig;
  final int? customerId;
  final String couponCode;

  factory SaleCheckoutDraft.fromCart({
    required List<CartLine> cart,
    required List<SaleCheckoutPaymentDraft> payments,
    PrinterConfig? invoicePrinterConfig,
    int? customerId,
    String couponCode = '',
  }) {
    return SaleCheckoutDraft(
      lines: cart
          .map(
            (line) => SaleCheckoutLineDraft(
              variantId: line.variant.id,
              quantity: line.quantity,
            ),
          )
          .toList(growable: false),
      payments: payments,
      invoicePrinterConfig: invoicePrinterConfig,
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
      'payments': payments.map((payment) => payment.toJson()).toList(),
      if (invoicePrinterConfig != null)
        'print_invoice': {
          'agent_id': invoicePrinterConfig!.agentId,
          'printer_endpoint': invoicePrinterConfig!.endpoint.toJson(),
        },
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
  });

  final double subtotal;
  final double discountTotal;
  final double total;
  final List<AppliedDiscountInfo> appliedDiscounts;
  final List<String> unappliedCouponCodes;
  final List<SaleLossLine> lossLines;

  factory SaleDiscountPreview.fromJson(Map<String, Object?> json) {
    return SaleDiscountPreview(
      subtotal: _moneyFromJson(json['subtotal']),
      discountTotal: _moneyFromJson(json['discount_total']),
      total: _moneyFromJson(json['total']),
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
  });

  final String ruleName;
  final String couponCode;
  final String source;
  final String scope;
  final String valueType;
  final double discountAmount;

  factory AppliedDiscountInfo.fromJson(Map<String, Object?> json) {
    return AppliedDiscountInfo(
      ruleName: json['rule_name']?.toString() ?? '',
      couponCode: json['coupon_code']?.toString() ?? '',
      source: json['source']?.toString() ?? '',
      scope: json['scope']?.toString() ?? '',
      valueType: json['value_type']?.toString() ?? '',
      discountAmount: _moneyFromJson(json['discount_amount']),
    );
  }
}

class SaleCheckoutPaymentDraft {
  const SaleCheckoutPaymentDraft({required this.method, required this.amount});

  final PaymentMethod method;
  final double amount;

  Map<String, Object?> toJson() {
    return {'method': method.apiValue, 'amount': amount.toStringAsFixed(2)};
  }
}

class SaleCheckoutLineDraft {
  const SaleCheckoutLineDraft({
    required this.variantId,
    required this.quantity,
  });

  final int variantId;
  final int quantity;

  Map<String, Object?> toJson() {
    return {'variant': variantId, 'quantity': quantity};
  }
}

class SaleOrder {
  const SaleOrder({
    required this.id,
    required this.status,
    required this.lines,
    required this.payments,
    required this.subtotal,
    required this.total,
    this.receiptNumber,
    this.registerSession,
    this.registerSessionNumber,
    this.customer,
    this.customerName,
    this.profit,
    this.profitMarginPercent,
    this.invoicePrintJob,
    this.canVoid = false,
    this.canReturn = false,
    this.requiresManagerAdjustment = false,
    this.discountTotal = 0,
    this.appliedDiscounts = const [],
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final String? receiptNumber;
  final String status;
  final int? registerSession;
  final String? registerSessionNumber;
  final int? customer;
  final String? customerName;
  final double? profit;
  final double? profitMarginPercent;
  final PrintJob? invoicePrintJob;
  final bool canVoid;
  final bool canReturn;
  final bool requiresManagerAdjustment;
  final List<SaleOrderLine> lines;
  final List<SalePayment> payments;
  final double subtotal;
  final double discountTotal;
  final double total;
  final List<AppliedDiscountInfo> appliedDiscounts;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory SaleOrder.fromJson(Map<String, Object?> json) {
    final linesJson = (json['lines'] as List<Object?>?) ?? const [];
    final paymentsJson = (json['payments'] as List<Object?>?) ?? const [];

    return SaleOrder(
      id: _intFromJson(json['id']),
      receiptNumber: json['receipt_number']?.toString(),
      status: json['status']?.toString() ?? '',
      registerSession: _nullableIntFromJson(json['register_session']),
      registerSessionNumber: json['register_session_number']?.toString(),
      customer: _nullableIntFromJson(json['customer']),
      customerName: json['customer_name']?.toString(),
      profit: _nullableMoneyFromJson(
        json['profit'] ?? json['gross_profit'] ?? json['total_profit'],
      ),
      profitMarginPercent: _nullableMoneyFromJson(
        json['profit_margin_percent'] ?? json['gross_margin_percent'],
      ),
      invoicePrintJob: json['print_job'] is Map<String, Object?>
          ? PrintJob.fromJson(json['print_job'] as Map<String, Object?>)
          : null,
      canVoid: _boolFromJson(json['can_void']),
      canReturn: _boolFromJson(json['can_return']),
      requiresManagerAdjustment: _boolFromJson(
        json['requires_manager_adjustment'],
      ),
      lines: linesJson
          .whereType<Map<String, Object?>>()
          .map(SaleOrderLine.fromJson)
          .toList(growable: false),
      payments: paymentsJson
          .whereType<Map<String, Object?>>()
          .map(SalePayment.fromJson)
          .toList(growable: false),
      subtotal: _moneyFromJson(json['subtotal']),
      discountTotal: _moneyFromJson(json['discount_total']),
      total: _moneyFromJson(json['total']),
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
    this.createdAt,
  });

  final int id;
  final PaymentMethod method;
  final double amount;
  final double commissionPercent;
  final double commissionAmount;
  final String externalReference;
  final DateTime? createdAt;

  factory SalePayment.fromJson(Map<String, Object?> json) {
    return SalePayment(
      id: _intFromJson(json['id']),
      method: PaymentMethod.fromApiValue(json['method']),
      amount: _moneyFromJson(json['amount']),
      commissionPercent: _moneyFromJson(json['commission_percent']),
      commissionAmount: _moneyFromJson(json['commission_amount']),
      externalReference: json['external_reference']?.toString() ?? '',
      createdAt: _dateTimeFromJson(json['created_at']),
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
  final int quantity;
  final int returnedQuantity;
  final int returnableQuantity;
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
      quantity: _intFromJson(json['quantity']),
      returnedQuantity: _intFromJson(json['returned_quantity']),
      returnableQuantity: _intFromJson(json['returnable_quantity']),
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

class SaleOrderQuery {
  const SaleOrderQuery({this.customerId, this.customerName});

  final int? customerId;
  final String? customerName;

  bool get hasCustomerFilter => customerId != null;

  Map<String, String> toQueryParameters({required int page}) {
    return {'page': '$page', if (customerId != null) 'customer': '$customerId'};
  }

  SaleOrderQuery withCustomer({int? id, String? name}) {
    return SaleOrderQuery(customerId: id, customerName: name);
  }
}

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
  final int quantity;

  Map<String, Object?> toJson() {
    return {'line': lineId, 'quantity': quantity};
  }
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
  return int.parse((value ?? 0).toString());
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
