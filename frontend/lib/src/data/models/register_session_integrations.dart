part of 'register_session_summary.dart';

/// Where a provider sale ended up. Stable codes from
/// `apps.integrations.session_breakdown`; the Arabic lives in the views.
enum SessionIntegrationBucket {
  /// Kept, and the provider confirmed it. The provider's share has left the
  /// agency float.
  delivered,

  /// Kept, and the provider has not performed it — never sent, or refused (an
  /// empty float is the usual reason). The customer paid for something they
  /// have not received yet.
  awaiting,

  /// Kept, sent, and nobody knows what happened. Must not be retried.
  unknown,

  /// The sale was voided or the line given back.
  refunded;

  static SessionIntegrationBucket fromJson(Object? value) {
    return switch (value?.toString()) {
      'delivered' => delivered,
      'unknown' => unknown,
      'refunded' => refunded,
      // A code this client does not know yet is treated as not delivered:
      // claiming a sale was performed is the one reading that must be earned.
      _ => awaiting,
    };
  }
}

/// Top-ups and cards a session sold for outside providers (HD Box, LNET,
/// Qareeb), and where their money went.
///
/// Every provider line the session rang up sits in exactly one
/// [SessionIntegrationBucket]. The headline figures — what customers paid,
/// the provider's share, the shop's profit — cover only the sales the shop
/// kept; refunds are counted beside them, and a refund the provider had
/// already performed is counted on its own because the float paid for it.
class SessionIntegrations {
  const SessionIntegrations({
    this.providers = const [],
    this.totals = SessionIntegrationFigures.empty,
    this.transactions = const [],
  });

  static const empty = SessionIntegrations();

  /// One entry per provider that sold anything this session, in the
  /// catalog's order.
  final List<SessionIntegrationFigures> providers;

  /// Every provider together.
  final SessionIntegrationFigures totals;

  /// Every provider line, oldest first.
  final List<SessionIntegrationTransaction> transactions;

  bool get hasActivity => providers.isNotEmpty;

  List<SessionIntegrationTransaction> transactionsFor(String provider) => [
    for (final transaction in transactions)
      if (transaction.provider == provider) transaction,
  ];

  factory SessionIntegrations.fromJson(Map<String, Object?> json) {
    return SessionIntegrations(
      providers: _list(
        json['providers'],
      ).map(SessionIntegrationFigures.fromJson).toList(growable: false),
      totals: SessionIntegrationFigures.fromJson(_map(json['totals'])),
      transactions: _list(
        json['transactions'],
      ).map(SessionIntegrationTransaction.fromJson).toList(growable: false),
    );
  }
}

/// One provider's money for a session — or every provider's, for the totals,
/// where [provider] is empty.
class SessionIntegrationFigures {
  const SessionIntegrationFigures({
    this.provider = '',
    required this.count,
    required this.sold,
    required this.cost,
    required this.margin,
    required this.delivered,
    required this.awaiting,
    required this.unknown,
    required this.refunded,
    required this.refundedAfterDelivery,
  });

  static const empty = SessionIntegrationFigures(
    count: 0,
    sold: 0,
    cost: 0,
    margin: 0,
    delivered: SessionIntegrationBucketTotals.empty,
    awaiting: SessionIntegrationBucketTotals.empty,
    unknown: SessionIntegrationBucketTotals.empty,
    refunded: SessionIntegrationBucketTotals.empty,
    refundedAfterDelivery: SessionIntegrationBucketTotals.empty,
  );

  /// The provider's stable key (`hdbox`, `lnet`, `qareeb`).
  final String provider;

  /// Sales the shop kept — everything but refunds.
  final int count;

  /// What customers paid for the kept sales.
  final double sold;

  /// The provider's share of [sold]: already out of the float for the
  /// delivered ones, still owed for the rest.
  final double cost;

  /// What the shop keeps once every kept sale is delivered.
  final double margin;

  final SessionIntegrationBucketTotals delivered;
  final SessionIntegrationBucketTotals awaiting;
  final SessionIntegrationBucketTotals unknown;

  /// [SessionIntegrationBucketTotals.amount] is what went back to customers.
  final SessionIntegrationBucketTotals refunded;

  /// Refunds of sales the provider had already performed. Its
  /// [SessionIntegrationBucketTotals.cost] is float money spent on sales the
  /// shop gave back. There is no amount: the refunds are inside [refunded].
  final SessionIntegrationBucketTotals refundedAfterDelivery;

  /// Every transaction rung up, refunded ones included.
  int get transactionCount => count + refunded.count;

  /// Something here is money at risk and wants a person to look at it.
  bool get needsAttention =>
      awaiting.count > 0 ||
      unknown.count > 0 ||
      refundedAfterDelivery.count > 0;

  SessionIntegrationBucketTotals bucket(SessionIntegrationBucket bucket) {
    return switch (bucket) {
      SessionIntegrationBucket.delivered => delivered,
      SessionIntegrationBucket.awaiting => awaiting,
      SessionIntegrationBucket.unknown => unknown,
      SessionIntegrationBucket.refunded => refunded,
    };
  }

  factory SessionIntegrationFigures.fromJson(Map<String, Object?> json) {
    return SessionIntegrationFigures(
      provider: (json['provider'] ?? '').toString(),
      count: _int(json['count']),
      sold: _money(json['sold']),
      cost: _money(json['cost']),
      margin: _money(json['margin']),
      delivered: SessionIntegrationBucketTotals.fromJson(
        _map(json['delivered']),
      ),
      awaiting: SessionIntegrationBucketTotals.fromJson(_map(json['awaiting'])),
      unknown: SessionIntegrationBucketTotals.fromJson(_map(json['unknown'])),
      refunded: SessionIntegrationBucketTotals.fromJson(_map(json['refunded'])),
      refundedAfterDelivery: SessionIntegrationBucketTotals.fromJson(
        _map(json['refunded_after_delivery']),
      ),
    );
  }
}

class SessionIntegrationBucketTotals {
  const SessionIntegrationBucketTotals({
    required this.count,
    required this.amount,
    required this.cost,
  });

  static const empty = SessionIntegrationBucketTotals(
    count: 0,
    amount: 0,
    cost: 0,
  );

  final int count;
  final double amount;
  final double cost;

  factory SessionIntegrationBucketTotals.fromJson(Map<String, Object?> json) {
    return SessionIntegrationBucketTotals(
      count: _int(json['count']),
      amount: _money(json['amount']),
      cost: _money(json['cost']),
    );
  }
}

/// One provider line a session rang up.
class SessionIntegrationTransaction {
  const SessionIntegrationTransaction({
    required this.id,
    required this.provider,
    this.kind = 'recharge',
    required this.orderId,
    this.receiptNumber = '',
    this.soldAt,
    this.subscriberRef = '',
    this.subscriberLabel = '',
    this.optionLabel = '',
    required this.price,
    required this.cost,
    this.refundedAmount = 0,
    required this.status,
    required this.bucket,
    this.errorCode = '',
    this.providerReference = '',
  });

  final int id;
  final String provider;

  /// `voucher` for a card off a provider's shelf, `recharge` for a top-up of
  /// somebody's line.
  final String kind;
  final int orderId;
  final String receiptNumber;
  final DateTime? soldAt;

  /// The card or line topped up. Blank for a card off the shelf.
  final String subscriberRef;

  /// Who the shop says owns it, if anybody has said.
  final String subscriberLabel;
  final String optionLabel;

  /// What the customer paid for this line.
  final double price;

  /// The provider's price for it.
  final double cost;

  /// What went back to the customer, for a refunded line.
  final double refundedAmount;

  /// The fulfillment's own state: pending · submitted · confirmed · failed ·
  /// cancelled.
  final String status;
  final SessionIntegrationBucket bucket;

  /// Why the provider did not perform it, as a code (e.g. an empty float).
  final String errorCode;
  final String providerReference;

  bool get isVoucher => kind == 'voucher';

  /// Refunded after the provider performed it: the float paid for a sale the
  /// shop gave back.
  bool get isRefundedAfterDelivery =>
      bucket == SessionIntegrationBucket.refunded && status == 'confirmed';

  factory SessionIntegrationTransaction.fromJson(Map<String, Object?> json) {
    return SessionIntegrationTransaction(
      id: _int(json['id']),
      provider: (json['provider'] ?? '').toString(),
      kind: (json['kind'] ?? 'recharge').toString(),
      orderId: _int(json['order_id']),
      receiptNumber: (json['receipt_number'] ?? '').toString(),
      soldAt: _dateTime(json['sold_at']),
      subscriberRef: (json['subscriber_ref'] ?? '').toString(),
      subscriberLabel: (json['subscriber_label'] ?? '').toString(),
      optionLabel: (json['option_label'] ?? '').toString(),
      price: _money(json['price']),
      cost: _money(json['cost']),
      refundedAmount: _money(json['refunded_amount']),
      status: (json['status'] ?? '').toString(),
      bucket: SessionIntegrationBucket.fromJson(json['bucket']),
      errorCode: (json['error_code'] ?? '').toString(),
      providerReference: (json['provider_reference'] ?? '').toString(),
    );
  }
}
