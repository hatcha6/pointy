import '../sandbox_payloads.dart';
import '../sandbox_request.dart';
import '../sandbox_shop.dart';

/// The drawer: opening it, moving cash through it, closing it.
SandboxReply handleRegister(SandboxShop shop, SandboxRequest request) {
  if (request.on('GET', 'register-sessions/current/') != null) {
    final session = shop.session;
    if (session == null || session.status != 'open') {
      // 204, not 404: the API signals "no session" with an empty success, and
      // a 404 here surfaces the app's "we cannot tell whether a session is
      // open" banner over the learner's first screen.
      return (204, null);
    }
    return (200, sessionJson(session));
  }
  if (request.on('GET', 'register-sessions/') != null) {
    final session = shop.session;
    return (200, page(session == null ? const [] : [sessionJson(session)]));
  }
  if (request.on('POST', 'register-sessions/start/') != null) {
    return (
      201,
      sessionJson(shop.openSession(openingCash: request.field('opening_cash'))),
    );
  }

  final close = request.on('POST', 'register-sessions/{id}/close/');
  if (close != null) {
    final closed = shop.closeSession(
      countedCash: request.field('closing_cash'),
    );
    if (closed == null) {
      return (400, {'detail': 'لا توجد وردية مفتوحة'});
    }
    return (200, sessionJson(closed));
  }

  final summary = request.on('GET', 'register-sessions/{id}/summary/');
  if (summary != null) {
    final session = shop.session;
    if (session == null) {
      return (404, {'detail': 'not found'});
    }
    return (
      200,
      {
        ...sessionJson(session),
        'order_count': shop.orders.length,
        'gross_sales_total': money(
          shop.orders.fold<double>(0, (sum, order) => sum + order.total),
        ),
        'payment_collected_total': money(
          shop.orders.fold<double>(0, (sum, order) => sum + order.paid),
        ),
        'payment_breakdown': const <Object?>[],
        'top_products': const <Object?>[],
      },
    );
  }

  final orders = request.on('GET', 'register-sessions/{id}/orders/');
  if (orders != null) {
    return (
      200,
      page([for (final order in shop.orders.reversed) orderJson(order)]),
    );
  }

  final movements = request.on('GET', 'register-sessions/{id}/cash-movements/');
  if (movements != null) {
    return (200, page(const []));
  }

  for (final direction in const ['pay-in', 'pay-out']) {
    if (request.on('POST', 'register-sessions/{id}/$direction/') != null) {
      final amount = request.field('amount');
      final kind = direction == 'pay-in' ? 'pay_in' : 'pay_out';
      shop.recordCashMovement(direction: kind, amount: amount);
      return (
        201,
        {
          'id': nextPracticeId(),
          'movement_type': kind,
          'amount': money(amount),
          'reason': request.text('reason'),
          'created_at': stamp(DateTime.now()),
        },
      );
    }
  }
  return null;
}
