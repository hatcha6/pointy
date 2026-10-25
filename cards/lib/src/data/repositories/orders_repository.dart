import 'package:flutter/foundation.dart';

import '../../core/money.dart';
import '../../core/result.dart';
import '../api/relay_api.dart';
import '../../features/card_payment/moamalat_client.dart';
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
}

/// Orders, payment and the customer's credit.
class OrdersRepository {
  OrdersRepository({required this.api, required this.channel});

  final RelayApi api;
  final String channel;

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
          },
        );
        changes.value++;
        return _order(answer);
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
        return order;
      });

  Future<Result<CardOrder>> cancel(String orderId) => Result.guard(() async {
    return _order(
      await api.post('/v1/customers/orders/$orderId/cancel', signedIn: true),
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
          _order(answer),
          session is Map<String, dynamic> ? CardSession.fromJson(session) : null,
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
    return order;
  });

  /// Where the card's bank sends the payer back after its 3-D Secure step;
  /// the app's web view stops there and reads the bank's answer.
  Uri get cardReturnUrl => api.resolve('/v1/customers/card-return');

  /// One order; a delivered one comes back with its codes.
  Future<Result<CardOrder>> order(String orderId) => Result.guard(() async {
    return _order(
      await api.get('/v1/customers/orders/$orderId', signedIn: true),
    );
  });

  Future<Result<List<CardOrder>>> orders() => Result.guard(() async {
    final answer = await api.get('/v1/customers/orders', signedIn: true);
    return [
      for (final row in (answer['orders'] as List? ?? const []))
        if (row is Map<String, dynamic>) CardOrder.fromJson(row),
    ];
  });

  Future<Result<CreditStatement>> credit() => Result.guard(() async {
    return CreditStatement.fromJson(
      await api.get('/v1/customers/credit', signedIn: true),
    );
  });

  static CardOrder _order(Map<String, dynamic> answer) =>
      CardOrder.fromJson(answer['order'] as Map<String, dynamic>? ?? const {});
}
