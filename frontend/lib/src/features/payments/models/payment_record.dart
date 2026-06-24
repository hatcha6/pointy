import '../../../data/models/sale_order.dart' show PaymentMethod;

/// A single customer money-IN payment as projected by the backend
/// `PaymentLedgerSerializer` (read-only). Mirrors the order's receipt number and
/// customer so the Payments hub can render a row without a second request.
class CustomerPaymentRecord {
  const CustomerPaymentRecord({
    required this.id,
    required this.method,
    required this.amount,
    required this.commissionAmount,
    required this.commissionPercent,
    required this.orderId,
    this.externalReference = '',
    this.orderReceiptNumber,
    this.customerId,
    this.customerName,
    this.createdByUsername,
    this.paidAt,
    this.createdAt,
  });

  final int id;
  final PaymentMethod method;
  final double amount;
  final double commissionAmount;
  final double commissionPercent;
  final String externalReference;
  final int orderId;
  final String? orderReceiptNumber;
  final int? customerId;
  final String? customerName;
  final String? createdByUsername;
  final DateTime? paidAt;
  final DateTime? createdAt;

  factory CustomerPaymentRecord.fromJson(Map<String, Object?> json) {
    return CustomerPaymentRecord(
      id: _intFromJson(json['id']),
      method: PaymentMethod.fromApiValue(json['method']),
      amount: _moneyFromJson(json['amount']),
      commissionAmount: _moneyFromJson(json['commission_amount']),
      commissionPercent: _moneyFromJson(json['commission_percent']),
      externalReference: json['external_reference']?.toString() ?? '',
      orderId: _intFromJson(json['order']),
      orderReceiptNumber: _nullableTrimmed(json['order_receipt_number']),
      customerId: _nullableIntFromJson(json['customer']),
      customerName: _nullableTrimmed(json['customer_name']),
      createdByUsername: _nullableTrimmed(json['created_by_username']),
      paidAt: _dateTimeFromJson(json['paid_at']),
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

/// One page of customer payments. Matches the app's `*Page` pattern: a list plus
/// a [hasMore] flag derived from DRF's `next` cursor.
class CustomerPaymentPage {
  const CustomerPaymentPage({required this.payments, required this.hasMore});

  final List<CustomerPaymentRecord> payments;
  final bool hasMore;

  factory CustomerPaymentPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(CustomerPaymentRecord.fromJson)
        .toList(growable: false);
    return CustomerPaymentPage(
      payments: results,
      hasMore: json['next'] != null,
    );
  }
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

String? _nullableTrimmed(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

DateTime? _dateTimeFromJson(Object? value) {
  final text = value?.toString() ?? '';
  if (text.isEmpty) {
    return null;
  }
  return DateTime.tryParse(text);
}
