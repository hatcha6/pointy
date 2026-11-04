import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/card_request.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_card_requests_controller.dart';

SaleOrder _sale({int lines = 1}) => SaleOrder(
  id: 50,
  status: 'paid',
  lines: [
    for (var line = 1; line <= lines; line++)
      SaleOrderLine.fromJson({
        'id': line,
        'variant': 9,
        'quantity': '1',
        'unit_price': '11.00',
        'total': '11.00',
        'integration': {
          'provider': 'pointy',
          'kind': 'recharge',
          'subscriber_ref': '51234$line',
          'option_label': 'ببجي 60',
        },
      }),
  ],
  payments: const [],
  subtotal: 11.0 * lines,
  total: 11.0 * lines,
  discountTotal: 0,
  amountPaid: 11.0 * lines,
  receiptNumber: 'INV-1',
);

CardRequest _row(int line, CardRequestState state, {int order = 50}) =>
    CardRequest(
      orderLine: line,
      orderId: order,
      state: state,
      label: 'ببجي 60',
    );

IntegrationChargeResult _working(int line) => IntegrationChargeResult(
  fulfillment: line,
  orderLine: line,
  outcome: 'unknown',
  status: 'submitted',
  inProgress: true,
  needsAttention: true,
);

void main() {
  late List<List<int>> asks;
  late List<Result<List<CardRequest>>> answers;
  late List<bool> ended;

  PosCardRequestsController build() {
    asks = [];
    answers = [];
    ended = [];
    return PosCardRequestsController(
      load: () async => const Ok([]),
      settle: (lines) async {
        asks.add(lines);
        return answers.isEmpty ? const Ok([]) : answers.removeAt(0);
      },
      onEnded: ended.add,
    );
  }

  test('asks nothing until the sale is handed over', () {
    fakeAsync((async) {
      final controller = build();
      controller.trackSale(_sale(), charge: Future.value([_working(1)]));
      async.elapse(const Duration(minutes: 1));
      expect(asks, isEmpty);
      expect(controller.openCount, 1);
      controller.dispose();
    });
  });

  test('a card answered while the dialog waits announces nothing', () {
    fakeAsync((async) {
      final controller = build();
      final ticket = controller.trackSale(
        _sale(),
        charge: Future.value([
          const IntegrationChargeResult(
            fulfillment: 1,
            orderLine: 1,
            outcome: 'charged',
          ),
        ]),
      );
      async.flushMicrotasks();
      ticket.close();
      expect(controller.requests.single.isSucceeded, isTrue);
      expect(controller.notices, isEmpty);
      expect(ended, isEmpty);
      async.elapse(const Duration(minutes: 1));
      expect(asks, isEmpty);
      controller.dispose();
    });
  });

  test('follows a handed-over order, eases off, and stops when it ends', () {
    fakeAsync((async) {
      final controller = build();
      final ticket = controller.trackSale(
        _sale(),
        charge: Future.value([_working(1)]),
      );
      async.flushMicrotasks();
      ticket.handOff();
      answers = [
        Ok([_row(1, CardRequestState.working)]),
        Ok([_row(1, CardRequestState.working)]),
        Ok([_row(1, CardRequestState.succeeded)]),
      ];
      async.elapse(const Duration(seconds: 2));
      expect(asks, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(asks.length, 1);
      async.elapse(const Duration(seconds: 3));
      expect(asks.length, 2);
      async.elapse(const Duration(seconds: 3));
      expect(asks.length, 2, reason: 'the third wait is longer');
      async.elapse(const Duration(seconds: 1));
      expect(asks.length, 3);
      expect(controller.openCount, 0);
      expect(ended, [true]);
      expect(controller.notices.single.orderLine, 1);
      expect(controller.unseenSucceeded, 1);
      async.elapse(const Duration(minutes: 5));
      expect(asks.length, 3, reason: 'nothing open, nothing asked');
      expect(controller.notices, isEmpty, reason: 'a success fades by itself');
      controller.dispose();
    });
  });

  test('a failure stays until it is read, and a lost read never stops it', () {
    fakeAsync((async) {
      final controller = build();
      final ticket = controller.trackSale(
        _sale(),
        charge: Future.value([_working(1)]),
      );
      async.flushMicrotasks();
      ticket.handOff();
      answers = [
        Error(Exception('offline')),
        Ok([_row(1, CardRequestState.failed)]),
      ];
      async.elapse(const Duration(seconds: 7));
      expect(asks.length, 2);
      expect(ended, [false]);
      async.elapse(const Duration(minutes: 5));
      expect(controller.notices.single.isFailed, isTrue);
      expect(controller.unseenFailed, 1);
      controller.setPanelOpen(true);
      expect(controller.notices, isEmpty);
      expect(controller.unseenFailed, 0);
      controller.dispose();
    });
  });

  test('prints one receipt, once every line of the sale has ended', () {
    fakeAsync((async) {
      final controller = build();
      final ticket = controller.trackSale(
        _sale(lines: 2),
        charge: Future.value([_working(1), _working(2)]),
      );
      async.flushMicrotasks();
      final printed = <List<IntegrationChargeResult>>[];
      ticket.handOff(
        printWhenDone: (performed) async {
          printed.add(performed);
          return null;
        },
      );
      answers = [
        Ok([
          _row(1, CardRequestState.succeeded),
          _row(2, CardRequestState.working),
        ]),
        Ok([
          _row(1, CardRequestState.succeeded),
          _row(2, CardRequestState.succeeded),
        ]),
      ];
      async.elapse(const Duration(seconds: 3));
      expect(printed, isEmpty);
      async.elapse(const Duration(seconds: 3));
      expect(printed.single.length, 2);
      async.elapse(const Duration(minutes: 1));
      expect(printed.length, 1);
      controller.dispose();
    });
  });

  test('prints nothing for a sale that delivered nothing', () {
    fakeAsync((async) {
      final controller = build();
      final ticket = controller.trackSale(
        _sale(),
        charge: Future.value([_working(1)]),
      );
      async.flushMicrotasks();
      var printed = 0;
      ticket.handOff(
        printWhenDone: (_) async {
          printed++;
          return null;
        },
      );
      answers = [
        Ok([_row(1, CardRequestState.failed)]),
      ];
      async.elapse(const Duration(seconds: 3));
      expect(printed, 0);
      controller.dispose();
    });
  });

  test('a late charge answer does not undo what a read-back settled', () {
    fakeAsync((async) {
      final controller = build();
      final charge = Completer<List<IntegrationChargeResult>>();
      final ticket = controller.trackSale(_sale(), charge: charge.future);
      ticket.handOff();
      answers = [
        Ok([_row(1, CardRequestState.succeeded)]),
      ];
      async.elapse(const Duration(seconds: 3));
      expect(controller.requests.single.isSucceeded, isTrue);
      charge.complete([_working(1)]);
      async.flushMicrotasks();
      expect(controller.requests.single.isSucceeded, isTrue);
      controller.dispose();
    });
  });

  test('opens on the history, following what is still open', () {
    fakeAsync((async) {
      final done = <bool>[];
      final asked = <List<int>>[];
      final controller = PosCardRequestsController(
        load: () async => Ok([
          _row(1, CardRequestState.working),
          _row(2, CardRequestState.succeeded, order: 51),
        ]),
        settle: (lines) async {
          asked.add(lines);
          return Ok([_row(1, CardRequestState.failed)]);
        },
        onEnded: done.add,
      );
      unawaited(controller.start());
      async.flushMicrotasks();
      expect(controller.requests.length, 2);
      expect(controller.requests.first.orderLine, 1, reason: 'open first');
      async.elapse(const Duration(seconds: 3));
      expect(asked.single, [1]);
      expect(done, [false]);
      controller.dispose();
    });
  });

  test('the key does nothing on a till with nothing to show', () {
    final controller = build();
    expect(controller.togglePanel(), isFalse);
    expect(controller.panelOpen, isFalse);
    controller.dispose();
  });
}
