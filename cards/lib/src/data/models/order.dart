import '../../core/money.dart';
import 'json.dart';

/// A customer's card order as the relay answers it.
class CardOrder {
  const CardOrder({
    required this.id,
    required this.status,
    required this.itemKey,
    required this.brandKey,
    required this.name,
    required this.quantity,
    required this.unitPrice,
    required this.total,
    required this.creditUsed,
    required this.amountDue,
    required this.fee,
    required this.amountToPay,
    required this.method,
    required this.payerHint,
    required this.nextAction,
    required this.checkoutUrl,
    required this.errorCode,
    required this.codes,
    required this.codesPending,
    required this.createdAt,
  });

  factory CardOrder.fromJson(Map<String, dynamic> json) => CardOrder(
    id: readString(json, 'id'),
    status: OrderStatus.parse(readString(json, 'status')),
    itemKey: readString(json, 'item'),
    brandKey: readString(json, 'brand'),
    name: readString(json, 'name'),
    quantity: readInt(json, 'quantity'),
    unitPrice: Money.parse(readString(json, 'unit_price')),
    total: Money.parse(readString(json, 'total')),
    creditUsed: Money.parse(readString(json, 'credit_used')),
    amountDue: Money.parse(readString(json, 'amount_due')),
    fee: Money.parse(readString(json, 'fee')),
    amountToPay: Money.parse(readString(json, 'amount_to_pay')),
    method: readString(json, 'method'),
    payerHint: readString(json, 'payer_hint'),
    nextAction: readString(json, 'next_action'),
    checkoutUrl: readString(json, 'checkout_url'),
    errorCode: readString(json, 'error_code'),
    codes: [for (final c in readList(json, 'codes')) CardCode.fromJson(c)],
    codesPending: readBool(json, 'codes_pending'),
    createdAt: readTime(json, 'created_at'),
  );

  final String id;
  final OrderStatus status;
  final String itemKey;
  final String brandKey;
  final String name;
  final int quantity;
  final Money unitPrice;
  final Money total;
  final Money creditUsed;
  final Money amountDue;
  final Money fee;

  /// What the payer is charged through Dafa: amount due plus the fee.
  final Money amountToPay;
  final String method;
  final String payerHint;

  /// "otp" (type the wallet's code) or "hosted_page" (pay on Dafa's page).
  final String nextAction;
  final String checkoutUrl;
  final String errorCode;
  final List<CardCode> codes;
  final bool codesPending;
  final DateTime? createdAt;
}

enum OrderStatus {
  awaitingPayment,
  paid,
  fulfilling,
  delivered,
  refunded,
  cancelled,
  failed,
  expired;

  static OrderStatus parse(String raw) => switch (raw) {
    'awaiting_payment' => awaitingPayment,
    'paid' => paid,
    'fulfilling' => fulfilling,
    'delivered' => delivered,
    'refunded' => refunded,
    'cancelled' => cancelled,
    'expired' => expired,
    _ => failed,
  };

  /// Still moving on its own: worth asking about again.
  bool get isOpen =>
      this == awaitingPayment || this == paid || this == fulfilling;
}

/// One card: the PIN to redeem, its serial, and how long it is good for.
class CardCode {
  const CardCode({
    required this.code,
    required this.serial,
    required this.expiry,
  });

  factory CardCode.fromJson(Map<String, dynamic> json) => CardCode(
    code: readString(json, 'code'),
    serial: readString(json, 'serial'),
    expiry: readString(json, 'expiry'),
  );

  final String code;
  final String serial;
  final String expiry;
}

/// A way to pay through Dafa (`GET /v1/customers/payment-methods`).
class PaymentMethod {
  const PaymentMethod({
    required this.key,
    required this.provider,
    required this.name,
    required this.kind,
    required this.payer,
    required this.birthYear,
  });

  factory PaymentMethod.fromJson(Map<String, dynamic> json) => PaymentMethod(
    key: readString(json, 'key'),
    provider: readString(json, 'provider'),
    name: readString(json, 'name'),
    kind: readString(json, 'kind'),
    payer: readString(json, 'payer'),
    birthYear: readBool(json, 'birth_year'),
  );

  final String key;
  final String provider;
  final String name;

  /// "otp" or "hosted_page".
  final String kind;

  /// What identifies the payer: "phone", "card" or "" (bank cards).
  final String payer;
  final bool birthYear;
}

/// The checkout's options and the fee shown before paying.
class CheckoutOptions {
  const CheckoutOptions({
    required this.methods,
    required this.feePercent,
    required this.maxQuantity,
    required this.testMode,
  });

  factory CheckoutOptions.fromJson(Map<String, dynamic> json) =>
      CheckoutOptions(
        methods: [
          for (final m in readList(json, 'methods')) PaymentMethod.fromJson(m),
        ],
        feePercent: double.tryParse(readString(json, 'fee_percent')) ?? 0,
        maxQuantity: readInt(json, 'max_quantity'),
        testMode: readBool(json, 'test_mode'),
      );

  final List<PaymentMethod> methods;
  final double feePercent;
  final int maxQuantity;
  final bool testMode;

  /// The fee on [due], worked out the relay's way: the payment is grossed up
  /// so the gateway's share of the whole is covered, rounded up to the cent.
  /// The relay's own figure on the placed order is the one charged.
  Money feeOn(Money due) {
    if (feePercent <= 0 || feePercent >= 100 || !due.isPositive) {
      return Money.zero;
    }
    final keptBasis = ((100 - feePercent) * 1000).round();
    // charge in cents, rounded up: due(dirhams) * 100000 / kept / 10
    final numerator = due.dirhams * 100000;
    final denominator = keptBasis * 10;
    final cents = (numerator + denominator - 1) ~/ denominator;
    return Money(cents * 10) - due;
  }
}

/// The customer's in-app credit.
class CreditStatement {
  const CreditStatement({required this.balance, required this.entries});

  factory CreditStatement.fromJson(Map<String, dynamic> json) =>
      CreditStatement(
        balance: Money.parse(readString(json, 'balance')),
        entries: [
          for (final e in readList(json, 'entries')) CreditEntry.fromJson(e),
        ],
      );

  final Money balance;
  final List<CreditEntry> entries;
}

class CreditEntry {
  const CreditEntry({
    required this.kind,
    required this.amount,
    required this.orderId,
    required this.createdAt,
  });

  factory CreditEntry.fromJson(Map<String, dynamic> json) => CreditEntry(
    kind: readString(json, 'kind'),
    amount: Money.parse(readString(json, 'amount')),
    orderId: readString(json, 'order_id'),
    createdAt: readTime(json, 'created_at'),
  );

  final String kind;
  final Money amount;
  final String orderId;
  final DateTime? createdAt;
}
