import '../models/order_report.dart';

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/analytics/analytics.dart';
import '../../core/analytics/events.dart';
import '../../core/money.dart';
import '../../core/result.dart';
import '../api/relay_api.dart';
import '../../features/card_payment/moamalat_client.dart';
import '../models/account_target.dart';
import '../models/order.dart';

/// What the checkout sends to place an order.
class OrderRequest {
  const OrderRequest({
    required this.itemKey,
    required this.quantity,
    required this.unitPrice,
    required this.idempotencyKey,
    this.useCredit = false,
    this.method = '',
    this.payerIdentifier = '',
    this.birthYear = '',
    this.account = const {},
  });

  final String itemKey;
  final int quantity;

  /// The price the customer was shown; the relay refuses another.
  final Money unitPrice;

  /// One per checkout attempt, so a retried tap never orders twice.
  final String idempotencyKey;
  final bool useCredit;
  final String method;
  final String payerIdentifier;
  final String birthYear;

  /// The account a top-up is sent to, by the brand's target fields.
  final Map<String, String> account;
}

/// Orders, payment and the customer's credit.
class OrdersRepository {
  OrdersRepository({
    required this.api,
    required this.channel,
    Analytics? analytics,
    this.preferences,
  }) : analytics = analytics ?? NoAnalytics();

  final RelayApi api;
  final String channel;

  /// Told when an order this phone saw open is paid, delivered or ends.
  final Analytics analytics;

  /// Keeps the orders still open across launches. Null in tests.
  final SharedPreferencesAsync? preferences;

  static const _followedKey = 'cards.followed_orders';

  /// The most open orders kept on the phone: the newest. One that is never
  /// read again (it left the list) must not stay there for good.
  static const _followedKept = 50;

  /// The last status seen of each order this phone saw open, so each step of
  /// its life is told once, however often it is asked about. The open ones
  /// are kept on the phone: a payment that lands after the app restarts is
  /// still told.
  final Map<String, OrderStatus> _followed = {};
  Future<void>? _restoring;

  /// Moves whenever an order is placed or paid here: the shelf listens, so
  /// «اشترِ مجدداً» and the credit follow a purchase at once.
  final ValueNotifier<int> changes = ValueNotifier(0);

  Future<Result<CheckoutOptions>> checkoutOptions() => Result.guard(() async {
    return CheckoutOptions.fromJson(
      await api.get('/v1/customers/payment-methods'),
    );
  });

  Future<Result<CardOrder>> place(OrderRequest request) =>
      Result.guard(() async {
        final answer = await api.post(
          '/v1/customers/orders',
          signedIn: true,
          body: {
            'item': request.itemKey,
            'quantity': request.quantity,
            'unit_price': request.unitPrice.toWire(),
            'idempotency_key': request.idempotencyKey,
            'channel': channel,
            'use_credit': request.useCredit,
            if (request.method.isNotEmpty) 'method': request.method,
            if (request.payerIdentifier.isNotEmpty)
              'user_identifier': request.payerIdentifier,
            if (request.birthYear.isNotEmpty) 'birth_year': request.birthYear,
            if (request.account.isNotEmpty) 'account': request.account,
          },
        );
        changes.value++;
        final order = _order(answer);
        analytics.orderPlaced(order);
        return _track(order, placed: true);
      });

  /// Looks up the account a top-up would go to, before anything is paid:
  /// the player's name when the game gives it. Nothing is ordered.
  Future<Result<AccountCheck>> checkAccount(
    String itemKey,
    Map<String, String> account,
  ) => Result.guard(() async {
    return AccountCheck.fromJson(
      await api.post(
        '/v1/customers/accounts/check',
        signedIn: true,
        body: {'item': itemKey, 'account': account},
      ),
    );
  });

  Future<Result<CardOrder>> confirm(String orderId, String otp) =>
      Result.guard(() async {
        final order = _order(
          await api.post(
            '/v1/customers/orders/$orderId/confirm',
            signedIn: true,
            body: {'otp': otp},
          ),
        );
        changes.value++;
        return _track(order);
      });

  Future<Result<CardOrder>> cancel(String orderId) => Result.guard(() async {
    return _track(
      _order(
        await api.post('/v1/customers/orders/$orderId/cancel', signedIn: true),
      ),
    );
  });

  /// The Moamalat checkout Dafa signed for a bank-card order, or none when
  /// the order is past paying (the order says how it ended). Refused with
  /// `card_form_unavailable` when the payer should use the payment page.
  Future<Result<(CardOrder, CardSession?)>> cardSession(String orderId) =>
      Result.guard(() async {
        final answer = await api.post(
          '/v1/customers/orders/$orderId/card',
          signedIn: true,
        );
        final session = answer['card_session'];
        return (
          await _track(_order(answer)),
          session is Map<String, dynamic>
              ? CardSession.fromJson(session)
              : null,
        );
      });

  /// Hands Moamalat's receipt to the relay, which passes it to Dafa and
  /// reads the payment back; the order comes back as it now stands.
  Future<Result<CardOrder>> completeCard(
    String orderId,
    Map<String, String> receipt,
  ) => Result.guard(() async {
    final order = _order(
      await api.post(
        '/v1/customers/orders/$orderId/card/complete',
        signedIn: true,
        body: {'receipt': receipt},
      ),
    );
    changes.value++;
    return _track(order);
  });

  /// Where the card's bank sends the payer back after its 3-D Secure step;
  /// the app's web view stops there and reads the bank's answer.
  Uri get cardReturnUrl => api.resolve('/v1/customers/card-return');

  /// One order; a delivered one comes back with its codes.
  /// Reports a problem with a paid order. Reporting it again while the first
  /// report is open answers that one: a second tap files nothing new.
  Future<Result<OrderReport>> report(
    String orderId, {
    required ReportReason reason,
    String note = '',
  }) => Result.guard(() async {
    final answer = await api.post(
      '/v1/customers/orders/$orderId/report',
      body: {'reason': reason.wire, 'note': note.trim()},
      signedIn: true,
    );
    return OrderReport.fromJson(answer['report'] as Map<String, dynamic>);
  });

  Future<Result<CardOrder>> order(String orderId) => Result.guard(() async {
    return _track(
      _order(await api.get('/v1/customers/orders/$orderId', signedIn: true)),
    );
  });

  Future<Result<List<CardOrder>>> orders() => Result.guard(() async {
    final customer = _customer;
    final answer = await api.get('/v1/customers/orders', signedIn: true);
    final list = [
      for (final row in (answer['orders'] as List? ?? const []))
        if (row is Map<String, dynamic>) CardOrder.fromJson(row),
    ];
    // An answer that was on its way while the customer changed is not kept.
    if (customer == _customer) {
      lastOrders = list;
      for (final order in list) {
        await _track(order);
      }
    }
    return list;
  });

  /// Moves with every [forget].
  int _customer = 0;

  /// The customer's orders as last read, so «كروتي» opens on them at once
  /// and reads again underneath. Null before the first read, and after
  /// [forget].
  List<CardOrder>? lastOrders;

  /// Whoever was signed in has gone: nothing of theirs is kept.
  void forget() {
    _customer++;
    lastOrders = null;
    _followed.clear();
    _restoring = Future.value();
    preferences?.remove(_followedKey).ignore();
  }

  Future<Result<CreditStatement>> credit() => Result.guard(() async {
    return CreditStatement.fromJson(
      await api.get('/v1/customers/credit', signedIn: true),
    );
  });

  /// The open orders kept from an earlier launch, read once.
  Future<void> _restore() => _restoring ??= () async {
    final customer = _customer;
    try {
      final saved = jsonDecode(
        await preferences?.getString(_followedKey) ?? '{}',
      );
      if (saved is Map && customer == _customer) {
        final statuses = OrderStatus.values.asNameMap();
        for (final MapEntry(:key, :value) in saved.entries) {
          final status = statuses[value];
          if (key is String && status != null) {
            _followed.putIfAbsent(key, () => status);
          }
        }
      }
    } on Exception {
      // Nothing kept: orders are followed from the next time they are seen.
    }
  }();

  Future<void> _save() async {
    final open = [
      for (final MapEntry(:key, :value) in _followed.entries)
        if (value.isOpen) MapEntry(key, value.name),
    ];
    try {
      await preferences?.setString(
        _followedKey,
        jsonEncode(
          Map.fromEntries(
            open.skip(
              open.length > _followedKept ? open.length - _followedKept : 0,
            ),
          ),
        ),
      );
    } on Exception {
      // Kept in memory for this launch all the same.
    }
  }

  /// Tells analytics how far an order this phone saw open has come since it
  /// was last seen: paid (once, whatever follows), delivered, or ended. An
  /// order first seen open is followed from then on; one first seen closed
  /// is past telling. An order [placed] here starts as awaiting payment.
  Future<CardOrder> _track(CardOrder order, {bool placed = false}) async {
    final customer = _customer;
    await _restore();
    // An answer that was on its way while the customer changed is not theirs
    // to follow.
    if (customer != _customer) {
      return order;
    }
    final before =
        _followed[order.id] ?? (placed ? OrderStatus.awaitingPayment : null);
    final now = order.status;
    if (_followed[order.id] == now || (before == null && !now.isOpen)) {
      return order;
    }
    _followed[order.id] = now;
    await _save();
    if (before == null) {
      return order;
    }
    bool paidBy(OrderStatus status) =>
        status == OrderStatus.paid ||
        status == OrderStatus.fulfilling ||
        status == OrderStatus.delivered;
    if (paidBy(now) && !paidBy(before)) {
      analytics.orderPaid(order);
    }
    if (now == OrderStatus.delivered) {
      analytics.orderDelivered(order);
    } else if (!now.isOpen) {
      analytics.orderEnded(order);
    }
    return order;
  }

  static CardOrder _order(Map<String, dynamic> answer) =>
      CardOrder.fromJson(answer['order'] as Map<String, dynamic>? ?? const {});
}
