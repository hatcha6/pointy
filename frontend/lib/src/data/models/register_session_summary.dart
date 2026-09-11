/// Full end-of-shift summary for a register session, across **all** payment
/// methods plus a sales-by-category breakdown and cash reconciliation.
///
/// Mirrors the backend `build_register_session_summary` payload
/// (`GET /register-sessions/{id}/summary/`). This single object feeds both the
/// manager session view and the printable Z-Report (thermal + PDF) so the
/// screen and the printouts can never disagree.
class RegisterSessionSummary {
  const RegisterSessionSummary({
    required this.sessionId,
    required this.sessionNumber,
    required this.status,
    required this.ownerName,
    this.openedAt,
    this.closedAt,
    required this.sales,
    required this.refunds,
    required this.paymentMethods,
    required this.paymentTotals,
    this.cardReceipts = CardReceiptTotals.empty,
    required this.categories,
    required this.cash,
    required this.expenses,
    required this.drawerPurchases,
  });

  final int sessionId;
  final String sessionNumber;
  final String status;
  final String ownerName;
  final DateTime? openedAt;
  final DateTime? closedAt;
  final SessionSalesTotals sales;
  final SessionRefundTotals refunds;
  final List<PaymentMethodBreakdown> paymentMethods;
  final PaymentMethodTotals paymentTotals;

  /// How much of [paymentTotals]' card money carries a checked receipt.
  final CardReceiptTotals cardReceipts;
  final List<CategoryBreakdown> categories;
  final SessionCashSummary cash;
  final SessionExpenseTotals expenses;

  /// Supplier purchases paid in cash from this drawer (POS cash purchases).
  /// Already inside [SessionCashSummary.payOutTotal]; broken out so the shift
  /// review can tell stock buys from generic pay-outs.
  final SessionExpenseTotals drawerPurchases;

  factory RegisterSessionSummary.fromJson(Map<String, Object?> json) {
    final session = _map(json['session']);
    return RegisterSessionSummary(
      sessionId: _int(session['id']),
      sessionNumber: (session['session_number'] ?? '').toString(),
      status: (session['status'] ?? '').toString(),
      ownerName: (session['owner_name'] ?? '').toString(),
      openedAt: _dateTime(session['opened_at']),
      closedAt: _dateTime(session['closed_at']),
      sales: SessionSalesTotals.fromJson(_map(json['sales'])),
      refunds: SessionRefundTotals.fromJson(_map(json['refunds'])),
      paymentMethods: _list(
        json['payment_methods'],
      ).map(PaymentMethodBreakdown.fromJson).toList(growable: false),
      paymentTotals: PaymentMethodTotals.fromJson(_map(json['payment_totals'])),
      cardReceipts: CardReceiptTotals.fromJson(_map(json['card_receipts'])),
      categories: _list(
        json['categories'],
      ).map(CategoryBreakdown.fromJson).toList(growable: false),
      cash: SessionCashSummary.fromJson(_map(json['cash'])),
      expenses: SessionExpenseTotals.fromJson(_map(json['expenses'])),
      drawerPurchases: SessionExpenseTotals.fromJson(
        _map(json['drawer_purchases']),
      ),
    );
  }
}

class SessionSalesTotals {
  const SessionSalesTotals({
    required this.grossSales,
    required this.discountTotal,
    required this.netSales,
    required this.orderCount,
    required this.voidCount,
    required this.itemsSold,
  });

  final double grossSales;
  final double discountTotal;
  final double netSales;
  final int orderCount;
  final int voidCount;

  /// Pre-formatted quantity string from the backend (e.g. `"3"`, `"1.5"`).
  final String itemsSold;

  factory SessionSalesTotals.fromJson(Map<String, Object?> json) {
    return SessionSalesTotals(
      grossSales: _money(json['gross_sales']),
      discountTotal: _money(json['discount_total']),
      netSales: _money(json['net_sales']),
      orderCount: _int(json['order_count']),
      voidCount: _int(json['void_count']),
      itemsSold: (json['items_sold'] ?? '0').toString(),
    );
  }
}

class SessionRefundTotals {
  const SessionRefundTotals({
    required this.refundTotal,
    required this.returnCount,
    required this.cashRefundTotal,
  });

  final double refundTotal;
  final int returnCount;
  final double cashRefundTotal;

  factory SessionRefundTotals.fromJson(Map<String, Object?> json) {
    return SessionRefundTotals(
      refundTotal: _money(json['refund_total']),
      returnCount: _int(json['return_count']),
      cashRefundTotal: _money(json['cash_refund_total']),
    );
  }

  bool get hasRefunds => refundTotal > 0;
}

class PaymentMethodBreakdown {
  const PaymentMethodBreakdown({
    required this.method,
    required this.gross,
    required this.commission,
    required this.refund,
    required this.net,
    required this.count,
  });

  /// One of `cash`, `card`, `transfer`.
  final String method;
  final double gross;
  final double commission;
  final double refund;
  final double net;
  final int count;

  factory PaymentMethodBreakdown.fromJson(Map<String, Object?> json) {
    return PaymentMethodBreakdown(
      method: (json['method'] ?? '').toString(),
      gross: _money(json['gross']),
      commission: _money(json['commission']),
      refund: _money(json['refund']),
      net: _money(json['net']),
      count: _int(json['count']),
    );
  }

  bool get hasActivity => count > 0 || gross != 0 || refund != 0;
}

class PaymentMethodTotals {
  const PaymentMethodTotals({
    required this.gross,
    required this.commission,
    required this.refund,
    required this.net,
    required this.count,
  });

  final double gross;
  final double commission;
  final double refund;
  final double net;
  final int count;

  factory PaymentMethodTotals.fromJson(Map<String, Object?> json) {
    return PaymentMethodTotals(
      gross: _money(json['gross']),
      commission: _money(json['commission']),
      refund: _money(json['refund']),
      net: _money(json['net']),
      count: _int(json['count']),
    );
  }
}

/// How much of a shift's card money is backed by a checked receipt.
///
/// The shift's card total says how much went through the terminal; it does not
/// say how much of that the shop can prove. Those part company the moment a
/// provider's receipt has to be proved *after* the sale, so the manager view
/// shows both — "2,000 verified of 4,000" — rather than one number that mixes
/// them.
class CardReceiptTotals {
  const CardReceiptTotals({
    required this.gross,
    required this.verified,
    required this.pending,
    required this.flagged,
    required this.unavailable,
    required this.noReceipt,
    required this.pendingCount,
    required this.flaggedCount,
  });

  /// Every card dinar taken this shift. The five buckets below sum to it.
  final double gross;

  /// Proved, and for the amount charged.
  final double verified;

  /// Scanned, still waiting on the issuer.
  final double pending;

  /// The issuer disowned it, or it proves a different amount. Needs a human.
  final double flagged;

  /// The issuer could not be reached. Says nothing about the receipt either way.
  final double unavailable;

  /// Card money taken with no receipt scanned at all.
  final double noReceipt;

  final int pendingCount;
  final int flaggedCount;

  static const empty = CardReceiptTotals(
    gross: 0,
    verified: 0,
    pending: 0,
    flagged: 0,
    unavailable: 0,
    noReceipt: 0,
    pendingCount: 0,
    flaggedCount: 0,
  );

  /// Whether there is anything to say. A shift with no card takings shows no
  /// card section rather than a row of zeroes.
  bool get hasCardPayments => gross > 0;

  /// Whether every dinar is accounted for and proved.
  bool get isFullyVerified => hasCardPayments && verified >= gross;

  /// Whether something needs a person to look at it.
  bool get needsAttention => flagged > 0;

  factory CardReceiptTotals.fromJson(Map<String, Object?> json) {
    final counts = _map(json['counts']);
    return CardReceiptTotals(
      gross: _money(json['gross']),
      verified: _money(json['verified']),
      pending: _money(json['pending']),
      flagged: _money(json['flagged']),
      unavailable: _money(json['unavailable']),
      noReceipt: _money(json['no_receipt']),
      pendingCount: _int(counts['pending']),
      flaggedCount: _int(counts['flagged']),
    );
  }
}

class CategoryBreakdown {
  const CategoryBreakdown({
    required this.category,
    required this.quantity,
    required this.net,
  });

  /// Category name, or `null` for the uncategorized bucket.
  final String? category;

  /// Pre-formatted quantity string from the backend (e.g. `"3"`, `"1.5"`).
  final String quantity;
  final double net;

  factory CategoryBreakdown.fromJson(Map<String, Object?> json) {
    return CategoryBreakdown(
      category: json['category']?.toString(),
      quantity: (json['quantity'] ?? '0').toString(),
      net: _money(json['net']),
    );
  }
}

class SessionCashSummary {
  const SessionCashSummary({
    required this.openingCash,
    required this.cashSalesTotal,
    required this.payInTotal,
    required this.payOutTotal,
    required this.cashRefundTotal,
    required this.expectedCash,
    this.closingCash,
    this.cashVariance,
    required this.hasCashVariance,
    required this.denominationTotal,
    required this.denominations,
  });

  final double openingCash;
  final double cashSalesTotal;
  final double payInTotal;
  final double payOutTotal;
  final double cashRefundTotal;
  final double expectedCash;
  final double? closingCash;
  final double? cashVariance;
  final bool hasCashVariance;
  final double denominationTotal;
  final List<DenominationCount> denominations;

  factory SessionCashSummary.fromJson(Map<String, Object?> json) {
    return SessionCashSummary(
      openingCash: _money(json['opening_cash']),
      cashSalesTotal: _money(json['cash_sales_total']),
      payInTotal: _money(json['pay_in_total']),
      payOutTotal: _money(json['pay_out_total']),
      cashRefundTotal: _money(json['cash_refund_total']),
      expectedCash: _money(json['expected_cash']),
      closingCash: _nullableMoney(json['closing_cash']),
      cashVariance: _nullableMoney(json['cash_variance']),
      hasCashVariance: json['has_cash_variance'] is bool
          ? json['has_cash_variance'] as bool
          : json['has_cash_variance']?.toString() == 'true',
      denominationTotal: _money(json['denomination_total']),
      denominations: _list(
        json['denominations'],
      ).map(DenominationCount.fromJson).toList(growable: false),
    );
  }
}

class DenominationCount {
  const DenominationCount({required this.value, required this.count});

  /// The coin value, pre-formatted (e.g. `"0.25"`).
  final String value;
  final int count;

  factory DenominationCount.fromJson(Map<String, Object?> json) {
    return DenominationCount(
      value: (json['value'] ?? '').toString(),
      count: _int(json['count']),
    );
  }
}

class SessionExpenseTotals {
  const SessionExpenseTotals({required this.total, required this.count});

  final double total;
  final int count;

  factory SessionExpenseTotals.fromJson(Map<String, Object?> json) {
    return SessionExpenseTotals(
      total: _money(json['total']),
      count: _int(json['count']),
    );
  }
}

double _money(Object? value) => double.tryParse((value ?? 0).toString()) ?? 0;

double? _nullableMoney(Object? value) {
  if (value == null) {
    return null;
  }
  return double.tryParse(value.toString());
}

int _int(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}

DateTime? _dateTime(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}

Map<String, Object?> _map(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, dynamic v) => MapEntry(key.toString(), v));
  }
  return const {};
}

List<Map<String, Object?>> _list(Object? value) {
  if (value is List) {
    return value.whereType<Map>().map(_map).toList(growable: false);
  }
  return const [];
}
