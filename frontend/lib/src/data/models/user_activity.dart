import 'pos_user.dart';

class UserActivityOverview {
  const UserActivityOverview({
    required this.user,
    required this.sales,
    required this.registerSessions,
    required this.cashMovements,
    required this.purchasing,
    required this.supplierPayments,
    required this.activity,
    required this.recentSales,
    required this.recentCreditSales,
    required this.recentPurchaseOrders,
    required this.recentRegisterSessions,
    required this.recentActivity,
  });

  final PosUser user;
  final UserSalesActivitySummary sales;
  final UserRegisterSessionActivitySummary registerSessions;
  final UserCashMovementActivitySummary cashMovements;
  final UserPurchasingActivitySummary purchasing;
  final UserSupplierPaymentActivitySummary supplierPayments;
  final UserAuditActivitySummary activity;

  /// Everything but the credit invoices — those are [recentCreditSales]. The
  /// two are disjoint server-side, so a debt is never counted on this screen
  /// twice.
  final List<UserRecentSale> recentSales;

  /// The آجل invoices this person issued, newest first. Read apart from the
  /// cash sales because a debt is money still owed, not a settled sale.
  final List<UserRecentSale> recentCreditSales;
  final List<UserRecentPurchaseOrder> recentPurchaseOrders;
  final List<UserRecentRegisterSession> recentRegisterSessions;
  final List<UserActivityEvent> recentActivity;

  factory UserActivityOverview.fromJson(Map<String, Object?> json) {
    final summary = _mapFromJson(json['summary']);

    return UserActivityOverview(
      user: PosUser.fromJson(_mapFromJson(json['user'])),
      sales: UserSalesActivitySummary.fromJson(_mapFromJson(summary['sales'])),
      registerSessions: UserRegisterSessionActivitySummary.fromJson(
        _mapFromJson(summary['register_sessions']),
      ),
      cashMovements: UserCashMovementActivitySummary.fromJson(
        _mapFromJson(summary['cash_movements']),
      ),
      purchasing: UserPurchasingActivitySummary.fromJson(
        _mapFromJson(summary['purchasing']),
      ),
      supplierPayments: UserSupplierPaymentActivitySummary.fromJson(
        _mapFromJson(summary['supplier_payments']),
      ),
      activity: UserAuditActivitySummary.fromJson(
        _mapFromJson(summary['activity']),
      ),
      recentSales: _listFromJson(json['recent_sales'])
          .whereType<Map<String, Object?>>()
          .map(UserRecentSale.fromJson)
          .toList(growable: false),
      recentCreditSales: _listFromJson(json['recent_credit_sales'])
          .whereType<Map<String, Object?>>()
          .map(UserRecentSale.fromJson)
          .toList(growable: false),
      recentPurchaseOrders: _listFromJson(json['recent_purchase_orders'])
          .whereType<Map<String, Object?>>()
          .map(UserRecentPurchaseOrder.fromJson)
          .toList(growable: false),
      recentRegisterSessions: _listFromJson(json['recent_register_sessions'])
          .whereType<Map<String, Object?>>()
          .map(UserRecentRegisterSession.fromJson)
          .toList(growable: false),
      recentActivity: _listFromJson(json['recent_activity'])
          .whereType<Map<String, Object?>>()
          .map(UserActivityEvent.fromJson)
          .toList(growable: false),
    );
  }
}

class UserSalesActivitySummary {
  const UserSalesActivitySummary({
    required this.invoiceCount,
    required this.paidInvoiceCount,
    required this.voidInvoiceCount,
    required this.creditInvoiceCount,
    required this.creditOutstandingTotal,
    required this.customerCount,
    required this.returnCount,
    required this.netSales,
    required this.voidTotal,
    required this.returnTotal,
    this.lastInvoiceAt,
  });

  final int invoiceCount;
  final int paidInvoiceCount;
  final int voidInvoiceCount;

  /// How many آجل invoices this person issued in total, and how much of that
  /// is still owed. The credit list on screen shows only the newest few, so
  /// these are what keep it from reading as the whole story.
  final int creditInvoiceCount;
  final double creditOutstandingTotal;
  final int customerCount;
  final int returnCount;
  final double netSales;
  final double voidTotal;
  final double returnTotal;
  final DateTime? lastInvoiceAt;

  factory UserSalesActivitySummary.fromJson(Map<String, Object?> json) {
    return UserSalesActivitySummary(
      invoiceCount: _intFromJson(json['invoice_count']),
      paidInvoiceCount: _intFromJson(json['paid_invoice_count']),
      voidInvoiceCount: _intFromJson(json['void_invoice_count']),
      creditInvoiceCount: _intFromJson(json['credit_invoice_count']),
      creditOutstandingTotal: _moneyFromJson(json['credit_outstanding_total']),
      customerCount: _intFromJson(json['customer_count']),
      returnCount: _intFromJson(json['return_count']),
      netSales: _moneyFromJson(json['net_sales']),
      voidTotal: _moneyFromJson(json['void_total']),
      returnTotal: _moneyFromJson(json['return_total']),
      lastInvoiceAt: _dateTimeFromJson(json['last_invoice_at']),
    );
  }
}

class UserRegisterSessionActivitySummary {
  const UserRegisterSessionActivitySummary({
    required this.sessionCount,
    required this.openCount,
    required this.closedCount,
    required this.varianceCount,
    required this.openingCashTotal,
    required this.closingCashTotal,
    this.lastSessionAt,
  });

  final int sessionCount;
  final int openCount;
  final int closedCount;
  final int varianceCount;
  final double openingCashTotal;
  final double closingCashTotal;
  final DateTime? lastSessionAt;

  factory UserRegisterSessionActivitySummary.fromJson(
    Map<String, Object?> json,
  ) {
    return UserRegisterSessionActivitySummary(
      sessionCount: _intFromJson(json['session_count']),
      openCount: _intFromJson(json['open_count']),
      closedCount: _intFromJson(json['closed_count']),
      varianceCount: _intFromJson(json['variance_count']),
      openingCashTotal: _moneyFromJson(json['opening_cash_total']),
      closingCashTotal: _moneyFromJson(json['closing_cash_total']),
      lastSessionAt: _dateTimeFromJson(json['last_session_at']),
    );
  }
}

class UserCashMovementActivitySummary {
  const UserCashMovementActivitySummary({
    required this.movementCount,
    required this.payInCount,
    required this.payOutCount,
    required this.payInTotal,
    required this.payOutTotal,
  });

  final int movementCount;
  final int payInCount;
  final int payOutCount;
  final double payInTotal;
  final double payOutTotal;

  factory UserCashMovementActivitySummary.fromJson(Map<String, Object?> json) {
    return UserCashMovementActivitySummary(
      movementCount: _intFromJson(json['movement_count']),
      payInCount: _intFromJson(json['pay_in_count']),
      payOutCount: _intFromJson(json['pay_out_count']),
      payInTotal: _moneyFromJson(json['pay_in_total']),
      payOutTotal: _moneyFromJson(json['pay_out_total']),
    );
  }
}

class UserPurchasingActivitySummary {
  const UserPurchasingActivitySummary({
    required this.purchaseOrderCount,
    required this.supplierInvoiceCount,
    required this.receivedOrderCount,
    required this.receiptCount,
    required this.adjustmentCount,
    required this.purchaseTotal,
    required this.adjustmentTotal,
    this.lastPurchaseAt,
  });

  final int purchaseOrderCount;
  final int supplierInvoiceCount;
  final int receivedOrderCount;
  final int receiptCount;
  final int adjustmentCount;
  final double purchaseTotal;
  final double adjustmentTotal;
  final DateTime? lastPurchaseAt;

  factory UserPurchasingActivitySummary.fromJson(Map<String, Object?> json) {
    return UserPurchasingActivitySummary(
      purchaseOrderCount: _intFromJson(json['purchase_order_count']),
      supplierInvoiceCount: _intFromJson(json['supplier_invoice_count']),
      receivedOrderCount: _intFromJson(json['received_order_count']),
      receiptCount: _intFromJson(json['receipt_count']),
      adjustmentCount: _intFromJson(json['adjustment_count']),
      purchaseTotal: _moneyFromJson(json['purchase_total']),
      adjustmentTotal: _moneyFromJson(json['adjustment_total']),
      lastPurchaseAt: _dateTimeFromJson(json['last_purchase_at']),
    );
  }
}

class UserSupplierPaymentActivitySummary {
  const UserSupplierPaymentActivitySummary({
    required this.paymentCount,
    required this.paymentTotal,
    required this.refundCount,
    required this.refundTotal,
    this.lastPaymentAt,
  });

  final int paymentCount;
  final double paymentTotal;
  final int refundCount;
  final double refundTotal;
  final DateTime? lastPaymentAt;

  factory UserSupplierPaymentActivitySummary.fromJson(
    Map<String, Object?> json,
  ) {
    return UserSupplierPaymentActivitySummary(
      paymentCount: _intFromJson(json['payment_count']),
      paymentTotal: _moneyFromJson(json['payment_total']),
      refundCount: _intFromJson(json['refund_count']),
      refundTotal: _moneyFromJson(json['refund_total']),
      lastPaymentAt: _dateTimeFromJson(json['last_payment_at']),
    );
  }
}

class UserAuditActivitySummary {
  const UserAuditActivitySummary({required this.eventCount, this.lastEventAt});

  final int eventCount;
  final DateTime? lastEventAt;

  factory UserAuditActivitySummary.fromJson(Map<String, Object?> json) {
    return UserAuditActivitySummary(
      eventCount: _intFromJson(json['event_count']),
      lastEventAt: _dateTimeFromJson(json['last_event_at']),
    );
  }
}

class UserRecentSale {
  const UserRecentSale({
    required this.id,
    required this.receiptNumber,
    required this.status,
    required this.total,
    this.customerName = '',
    this.registerSessionNumber = '',
    this.saleType = '',
    this.amountPaid = 0,
    this.balanceDue = 0,
    this.paymentStatus = '',
    this.dueDate,
    this.isOverdue = false,
    this.createdAt,
  });

  final int id;
  final String receiptNumber;
  final String status;
  final String customerName;
  final String registerSessionNumber;
  final double total;

  /// `standard` | `credit` | `quotation`.
  final String saleType;

  /// What is still owed on this invoice, and how it stands. Carried on every
  /// row but only meaningful on a credit (آجل) one — a cash sale is settled at
  /// the counter.
  final double amountPaid;
  final double balanceDue;
  final String paymentStatus;
  final DateTime? dueDate;
  final bool isOverdue;
  final DateTime? createdAt;

  factory UserRecentSale.fromJson(Map<String, Object?> json) {
    return UserRecentSale(
      id: _intFromJson(json['id']),
      receiptNumber: json['receipt_number']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      customerName: json['customer_name']?.toString() ?? '',
      registerSessionNumber: json['register_session_number']?.toString() ?? '',
      total: _moneyFromJson(json['total']),
      saleType: json['sale_type']?.toString() ?? '',
      amountPaid: _moneyFromJson(json['amount_paid']),
      balanceDue: _moneyFromJson(json['balance_due']),
      paymentStatus: json['payment_status']?.toString() ?? '',
      dueDate: _dateTimeFromJson(json['due_date']),
      isOverdue: json['is_overdue'] == true,
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

class UserRecentPurchaseOrder {
  const UserRecentPurchaseOrder({
    required this.id,
    required this.orderNumber,
    required this.status,
    required this.supplierName,
    required this.total,
    this.supplierInvoiceNumber = '',
    this.supplierInvoiceDate,
    this.createdAt,
  });

  final int id;
  final String orderNumber;
  final String status;
  final String supplierName;
  final String supplierInvoiceNumber;
  final DateTime? supplierInvoiceDate;
  final double total;
  final DateTime? createdAt;

  factory UserRecentPurchaseOrder.fromJson(Map<String, Object?> json) {
    return UserRecentPurchaseOrder(
      id: _intFromJson(json['id']),
      orderNumber: json['order_number']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      supplierName: json['supplier_name']?.toString() ?? '',
      supplierInvoiceNumber: json['supplier_invoice_number']?.toString() ?? '',
      supplierInvoiceDate: _dateTimeFromJson(json['supplier_invoice_date']),
      total: _moneyFromJson(json['total']),
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

class UserRecentRegisterSession {
  const UserRecentRegisterSession({
    required this.id,
    required this.sessionNumber,
    required this.status,
    required this.openingCash,
    required this.hasCashVariance,
    this.closingCash,
    this.cashVariance,
    this.openedAt,
    this.closedAt,
  });

  final int id;
  final String sessionNumber;
  final String status;
  final double openingCash;
  final double? closingCash;
  final double? cashVariance;
  final bool hasCashVariance;
  final DateTime? openedAt;
  final DateTime? closedAt;

  factory UserRecentRegisterSession.fromJson(Map<String, Object?> json) {
    return UserRecentRegisterSession(
      id: _intFromJson(json['id']),
      sessionNumber: json['session_number']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      openingCash: _moneyFromJson(json['opening_cash']),
      closingCash: _nullableMoneyFromJson(json['closing_cash']),
      cashVariance: _nullableMoneyFromJson(json['cash_variance']),
      hasCashVariance: _boolFromJson(json['has_cash_variance']),
      openedAt: _dateTimeFromJson(json['opened_at']),
      closedAt: _dateTimeFromJson(json['closed_at']),
    );
  }
}

class UserActivityEvent {
  const UserActivityEvent({
    required this.id,
    required this.name,
    required this.eventType,
    required this.severity,
    this.entityType = '',
    this.entityId = '',
    this.occurredAt,
  });

  final int id;
  final String name;
  final String eventType;
  final String severity;
  final String entityType;
  final String entityId;
  final DateTime? occurredAt;

  factory UserActivityEvent.fromJson(Map<String, Object?> json) {
    return UserActivityEvent(
      id: _intFromJson(json['id']),
      name: json['name']?.toString() ?? '',
      eventType: json['event_type']?.toString() ?? '',
      severity: json['severity']?.toString() ?? '',
      entityType: json['entity_type']?.toString() ?? '',
      entityId: json['entity_id']?.toString() ?? '',
      occurredAt: _dateTimeFromJson(json['occurred_at']),
    );
  }
}

Map<String, Object?> _mapFromJson(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return const {};
}

List<Object?> _listFromJson(Object? value) {
  if (value is List<Object?>) {
    return value;
  }
  if (value is Iterable) {
    return value.toList(growable: false);
  }
  return const [];
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}

double _moneyFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse((value ?? 0).toString()) ?? 0;
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

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
