/// Payments made on a provider's own website (LNET), and recording one as the
/// sale it was.
///
/// The backend mirrors the provider's account-wide payments report and says,
/// for every payment, where it stands in Pointy. The codes are its contract
/// (`apps.integrations.portal_sales`); the Arabic lives in the l10n files.
library;

double? _toDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

int? _toIntOrNull(Object? value) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '');
}

DateTime? _toDate(Object? value) {
  final raw = value?.toString();
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}

List<Map<String, Object?>> _maps(Object? value) {
  return (value as List<Object?>? ?? const [])
      .whereType<Map<String, Object?>>()
      .toList(growable: false);
}

/// Where one website payment stands in Pointy.
enum PortalPaymentState {
  /// A Pointy sale already accounts for it.
  recorded,

  /// It was recorded, and that invoice has since been voided. It may be
  /// recorded again — the way a wrong drawer or payment method is corrected.
  released,

  /// A Pointy sale that took the customer's money and still waits for its
  /// top-up could be this very payment.
  pendingSale,

  /// A real, finished payment with no sale behind it.
  unrecorded,

  /// The provider does not call it done: pending, cancelled, or a
  /// cancellation in flight.
  notVerified,

  /// Made by another login under the agency.
  otherOperator,

  /// Not a plain top-up (extra data bought with it, or missing its amount).
  unsupported,

  /// A code this build does not know. Never recordable.
  unknown;

  static PortalPaymentState fromApiValue(Object? value) {
    return switch (value?.toString()) {
      'recorded' => recorded,
      'released' => released,
      'pending_sale' => pendingSale,
      'unrecorded' => unrecorded,
      'not_verified' => notVerified,
      'other_operator' => otherOperator,
      'unsupported' => unsupported,
      _ => unknown,
    };
  }

  /// Still owes the shop an invoice.
  bool get needsRecording =>
      this == unrecorded || this == released || this == pendingSale;
}

/// The invoice a payment is — or could be — accounted for by.
class PortalPaymentOrder {
  const PortalPaymentOrder({
    required this.id,
    this.receiptNumber = '',
    this.status = '',
    this.saleType = '',
    this.total,
    this.registerSessionId,
    this.sessionNumber = '',
    this.cashierName = '',
  });

  final int id;
  final String receiptNumber;
  final String status;
  final String saleType;
  final double? total;
  final int? registerSessionId;
  final String sessionNumber;
  final String cashierName;

  bool get isCredit => saleType == 'credit';

  factory PortalPaymentOrder.fromJson(Map<String, Object?> json) {
    return PortalPaymentOrder(
      id: _toIntOrNull(json['id']) ?? 0,
      receiptNumber: json['receipt_number']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      saleType: json['sale_type']?.toString() ?? '',
      total: _toDouble(json['total']),
      registerSessionId: _toIntOrNull(json['register_session_id']),
      sessionNumber: json['session_number']?.toString() ?? '',
      cashierName: json['cashier_name']?.toString() ?? '',
    );
  }
}

/// A Pointy sale waiting for its top-up that a website payment could be.
class PortalPaymentCandidate {
  const PortalPaymentCandidate({
    required this.fulfillmentId,
    required this.order,
    this.status = '',
    this.soldAt,
  });

  final int fulfillmentId;
  final PortalPaymentOrder order;
  final String status;
  final DateTime? soldAt;

  factory PortalPaymentCandidate.fromJson(Map<String, Object?> json) {
    return PortalPaymentCandidate(
      fulfillmentId: _toIntOrNull(json['fulfillment_id']) ?? 0,
      status: json['status']?.toString() ?? '',
      soldAt: _toDate(json['sold_at']),
      order: PortalPaymentOrder.fromJson(
        json['order'] as Map<String, Object?>? ?? const {},
      ),
    );
  }
}

/// One payment in the provider's report.
class PortalPayment {
  const PortalPayment({
    required this.reference,
    required this.state,
    this.paidAt,
    this.amount,
    this.cost,
    this.subscriberRef = '',
    this.subscriberName = '',
    this.customerId,
    this.operatorName = '',
    this.providerStatus = '',
    this.providerStatusLabel = '',
    this.recordable = false,
    this.price,
    this.order,
    this.candidates = const [],
    this.releasedOrderIds = const [],
  });

  /// The provider's serial for it — what its support asks for.
  final String reference;
  final PortalPaymentState state;
  final DateTime? paidAt;

  /// Face value paid onto the line.
  final double? amount;

  /// The agency float's share of it.
  final double? cost;

  /// The line that was paid (LNET: the username).
  final String subscriberRef;

  /// Who the shop knows that line as, when it has named it.
  final String subscriberName;
  final int? customerId;
  final String operatorName;

  /// The provider's own state for it, as a stable code, and as it printed it.
  final String providerStatus;
  final String providerStatusLabel;

  /// The server's answer to "may this be recorded as a sale now".
  final bool recordable;

  /// What recording it would charge — the till's own price for the amount.
  final double? price;

  /// The invoice that accounts for it, once one does.
  final PortalPaymentOrder? order;
  final List<PortalPaymentCandidate> candidates;
  final List<int> releasedOrderIds;

  factory PortalPayment.fromJson(Map<String, Object?> json) {
    final order = json['order'];
    return PortalPayment(
      reference: json['reference']?.toString() ?? '',
      state: PortalPaymentState.fromApiValue(json['state']),
      paidAt: _toDate(json['paid_at']),
      amount: _toDouble(json['amount']),
      cost: _toDouble(json['cost']),
      subscriberRef: json['subscriber_ref']?.toString() ?? '',
      subscriberName: json['subscriber_name']?.toString() ?? '',
      customerId: _toIntOrNull(json['customer_id']),
      operatorName: json['operator_name']?.toString() ?? '',
      providerStatus: json['provider_status']?.toString() ?? '',
      providerStatusLabel: json['provider_status_label']?.toString() ?? '',
      recordable: json['recordable'] == true,
      price: _toDouble(json['price']),
      order: order is Map<String, Object?>
          ? PortalPaymentOrder.fromJson(order)
          : null,
      candidates: _maps(
        json['candidates'],
      ).map(PortalPaymentCandidate.fromJson).toList(growable: false),
      releasedOrderIds: (json['released_order_ids'] as List<Object?>? ?? [])
          .map(_toIntOrNull)
          .whereType<int>()
          .toList(growable: false),
    );
  }
}

/// A register session a payment could be recorded into.
class PortalPaymentSession {
  const PortalPaymentSession({
    required this.id,
    this.sessionNumber = '',
    this.cashierName = '',
    this.ownerId,
    this.isOpen = true,
    this.openedAt,
    this.closedAt,
    this.cashVariance,
  });

  final int id;
  final String sessionNumber;
  final String cashierName;
  final int? ownerId;
  final bool isOpen;
  final DateTime? openedAt;
  final DateTime? closedAt;

  /// A closed shift's counted variance — over (positive) or short. The
  /// overage a website top-up left in the count is how a manager recognises
  /// the drawer it belongs to.
  final double? cashVariance;

  /// How long after a shift closed a payment may still be stamped and have
  /// been in its count. Mirrors the server's `SHIFT_CLOSE_SLACK`.
  static const closeSlack = Duration(minutes: 15);

  /// Whether this drawer was open at [moment].
  bool wasOpenAt(DateTime moment) {
    final opened = openedAt;
    if (opened != null && moment.isBefore(opened)) return false;
    final closed = closedAt;
    return isOpen || closed == null || !moment.isAfter(closed.add(closeSlack));
  }

  /// A closed drawer counted before [moment] cannot have held its cash. The
  /// server refuses it; the sheet does not offer it.
  bool closedBefore(DateTime moment) {
    final closed = closedAt;
    return !isOpen && closed != null && moment.isAfter(closed.add(closeSlack));
  }

  factory PortalPaymentSession.fromJson(Map<String, Object?> json) {
    return PortalPaymentSession(
      id: _toIntOrNull(json['id']) ?? 0,
      sessionNumber: json['session_number']?.toString() ?? '',
      cashierName: json['cashier_name']?.toString() ?? '',
      ownerId: _toIntOrNull(json['owner_id']),
      isOpen: (json['status']?.toString() ?? 'open') == 'open',
      openedAt: _toDate(json['opened_at']),
      closedAt: _toDate(json['closed_at']),
      cashVariance: _toDouble(json['cash_variance']),
    );
  }
}

/// One shop-local day of the provider's report, and everything the record
/// sheet needs to ask for what the checkout will.
class PortalPaymentsDay {
  const PortalPaymentsDay({
    required this.provider,
    this.date,
    this.currency = 'LYD',
    this.readOk = true,
    this.readErrorCode = '',
    this.readAt,
    this.complete = false,
    this.payments = const [],
    this.unrecordedCount = 0,
    this.unrecordedAmount = 0,
    this.pendingSaleCount = 0,
    this.sessions = const [],
    this.paymentMethods = const ['cash', 'card', 'transfer'],
    this.requireCustomerForCredit = true,
    this.requireCardReceipt = false,
  });

  final String provider;
  final DateTime? date;
  final String currency;

  /// Whether the provider could be read just now. The listed payments are
  /// real either way; only a fresh read may call the day complete.
  final bool readOk;
  final String readErrorCode;

  /// When the provider's report was last read — the moment "every payment"
  /// is true up to.
  final DateTime? readAt;
  final bool complete;
  final List<PortalPayment> payments;
  final int unrecordedCount;
  final double unrecordedAmount;
  final int pendingSaleCount;
  final List<PortalPaymentSession> sessions;

  /// The till methods this shop takes, by API value.
  final List<String> paymentMethods;
  final bool requireCustomerForCredit;
  final bool requireCardReceipt;

  factory PortalPaymentsDay.fromJson(Map<String, Object?> json) {
    final summary = json['summary'] as Map<String, Object?>? ?? const {};
    final rawDate = json['date']?.toString();
    return PortalPaymentsDay(
      provider: json['provider']?.toString() ?? '',
      date: rawDate == null ? null : DateTime.tryParse(rawDate),
      currency: json['currency']?.toString() ?? 'LYD',
      readOk: json['read_ok'] != false,
      readErrorCode: json['read_error_code']?.toString() ?? '',
      readAt: _toDate(json['read_at']),
      complete: json['complete'] == true,
      payments: _maps(
        json['payments'],
      ).map(PortalPayment.fromJson).toList(growable: false),
      unrecordedCount: _toIntOrNull(summary['unrecorded_count']) ?? 0,
      unrecordedAmount: _toDouble(summary['unrecorded_amount']) ?? 0,
      pendingSaleCount: _toIntOrNull(summary['pending_sale_count']) ?? 0,
      sessions: _maps(
        json['sessions'],
      ).map(PortalPaymentSession.fromJson).toList(growable: false),
      paymentMethods: (json['payment_methods'] as List<Object?>? ?? const [])
          .map((value) => value.toString())
          .toList(growable: false),
      requireCustomerForCredit: json['require_customer_for_credit'] != false,
      requireCardReceipt: json['require_card_receipt'] == true,
    );
  }
}

/// How the customer paid for a top-up done on the website.
class PortalPaymentRecordDraft {
  const PortalPaymentRecordDraft({
    required this.registerSessionId,
    this.isCredit = false,
    this.paymentMethod = 'cash',
    this.amountPaid,
    this.customerId,
    this.cardReceiptUrl = '',
    this.moneyAccountId,
    this.allowPendingSale = false,
    this.expectedTotal,
  });

  final int registerSessionId;

  /// آجل: the rest is owed by [customerId].
  final bool isCredit;

  /// Empty on an آجل invoice with nothing paid down.
  final String paymentMethod;

  /// آجل only: what was paid now.
  final double? amountPaid;
  final int? customerId;
  final String cardReceiptUrl;
  final int? moneyAccountId;

  /// The manager has seen a sale waiting for this line's top-up and says
  /// this payment is a different one.
  final bool allowPendingSale;

  /// The total the manager was shown; the server refuses a different one.
  final double? expectedTotal;

  Map<String, Object?> toJson() => {
    'register_session': registerSessionId,
    'sale_type': isCredit ? 'credit' : 'standard',
    'payment_method': paymentMethod,
    if (isCredit && amountPaid != null)
      'amount_paid': amountPaid!.toStringAsFixed(2),
    'customer': ?customerId,
    if (cardReceiptUrl.isNotEmpty) 'card_receipt_url': cardReceiptUrl,
    'money_account': ?moneyAccountId,
    if (allowPendingSale) 'allow_pending_sale': true,
    if (expectedTotal != null)
      'expected_total': expectedTotal!.toStringAsFixed(2),
  };
}

/// The server said no, with a stable reason.
class PortalPaymentRefusal implements Exception {
  const PortalPaymentRefusal(
    this.code, {
    this.detail = '',
    this.orderId,
    this.orderIds = const [],
    this.total,
  });

  final String code;
  final String detail;

  /// `already_recorded`: the invoice that accounts for it.
  final int? orderId;

  /// `pending_sale`: the sales waiting for this line's top-up.
  final List<int> orderIds;

  /// `price_changed`: what the invoice would charge now.
  final double? total;

  /// The refusal in a response body, or null when it carries no code.
  static PortalPaymentRefusal? fromBody(Object? body) {
    if (body is! Map<String, Object?>) return null;
    final code = body['code']?.toString() ?? '';
    if (code.isEmpty) return null;
    return PortalPaymentRefusal(
      code,
      detail: body['detail']?.toString() ?? '',
      orderId: _toIntOrNull(body['order_id']),
      orderIds: (body['order_ids'] as List<Object?>? ?? const [])
          .map(_toIntOrNull)
          .whereType<int>()
          .toList(growable: false),
      total: _toDouble(body['total']),
    );
  }

  @override
  String toString() => 'PortalPaymentRefusal($code)';
}
