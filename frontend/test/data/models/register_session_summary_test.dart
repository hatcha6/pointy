import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/register_session_summary.dart';

void main() {
  Map<String, Object?> sampleJson() => {
    'session': {
      'id': 7,
      'session_number': 'RS-7',
      'status': 'closed',
      'owner_name': 'Alice',
      'opened_at': '2026-06-24T08:00:00Z',
      'closed_at': '2026-06-24T20:00:00Z',
    },
    'sales': {
      'gross_sales': '120.00',
      'discount_total': '5.00',
      'net_sales': '110.00',
      'order_count': 8,
      'void_count': 1,
      'items_sold': '23',
    },
    'refunds': {
      'refund_total': '5.00',
      'return_count': 1,
      'cash_refund_total': '5.00',
    },
    'payment_methods': [
      {
        'method': 'cash',
        'gross': '60.00',
        'commission': '0.00',
        'refund': '5.00',
        'net': '55.00',
        'count': 5,
      },
      {
        'method': 'card',
        'gross': '40.00',
        'commission': '1.20',
        'refund': '0.00',
        'net': '40.00',
        'count': 2,
      },
      {
        'method': 'transfer',
        'gross': '0.00',
        'commission': '0.00',
        'refund': '0.00',
        'net': '0.00',
        'count': 0,
      },
    ],
    'payment_totals': {
      'gross': '100.00',
      'commission': '1.20',
      'refund': '5.00',
      'net': '95.00',
      'count': 7,
    },
    'categories': [
      {'category': 'Drinks', 'quantity': '3', 'net': '30.00'},
      {'category': null, 'quantity': '1.5', 'net': '7.00'},
    ],
    'cash': {
      'opening_cash': '50.00',
      'cash_sales_total': '60.00',
      'pay_in_total': '0.00',
      'pay_out_total': '0.00',
      'cash_refund_total': '5.00',
      'expected_cash': '105.00',
      'closing_cash': '104.00',
      'cash_variance': '-1.00',
      'has_cash_variance': true,
      'denomination_total': '4.00',
      'denominations': [
        {'value': '0.25', 'count': 4},
        {'value': '0.50', 'count': 2},
        {'value': '0.75', 'count': 0},
        {'value': '1.00', 'count': 2},
      ],
    },
    'expenses': {'total': '12.50', 'count': 2},
  };

  test('parses the full summary payload', () {
    final summary = RegisterSessionSummary.fromJson(sampleJson());

    expect(summary.sessionId, 7);
    expect(summary.sessionNumber, 'RS-7');
    expect(summary.status, 'closed');
    expect(summary.ownerName, 'Alice');
    expect(summary.openedAt, isNotNull);
    expect(summary.closedAt, isNotNull);

    expect(summary.sales.grossSales, 120.0);
    expect(summary.sales.netSales, 110.0);
    expect(summary.sales.orderCount, 8);
    expect(summary.sales.voidCount, 1);
    expect(summary.sales.itemsSold, '23');

    expect(summary.refunds.refundTotal, 5.0);
    expect(summary.refunds.hasRefunds, isTrue);

    expect(summary.paymentMethods, hasLength(3));
    final cash = summary.paymentMethods.firstWhere((m) => m.method == 'cash');
    expect(cash.gross, 60.0);
    expect(cash.refund, 5.0);
    expect(cash.net, 55.0);
    expect(cash.count, 5);
    expect(cash.hasActivity, isTrue);
    final transfer = summary.paymentMethods.firstWhere(
      (m) => m.method == 'transfer',
    );
    expect(transfer.hasActivity, isFalse);
    expect(summary.paymentTotals.net, 95.0);
  });

  test('parses categories including the uncategorized (null) bucket', () {
    final summary = RegisterSessionSummary.fromJson(sampleJson());

    expect(summary.categories, hasLength(2));
    expect(summary.categories.first.category, 'Drinks');
    expect(summary.categories.first.quantity, '3');
    expect(summary.categories.first.net, 30.0);
    // Uncategorized bucket comes through as a null category name.
    expect(summary.categories[1].category, isNull);
    expect(summary.categories[1].quantity, '1.5');
  });

  test('parses cash reconciliation with nullable closing/variance', () {
    final summary = RegisterSessionSummary.fromJson(sampleJson());
    final cash = summary.cash;

    expect(cash.openingCash, 50.0);
    expect(cash.expectedCash, 105.0);
    expect(cash.closingCash, 104.0);
    expect(cash.cashVariance, -1.0);
    expect(cash.hasCashVariance, isTrue);
    expect(cash.denominations, hasLength(4));
    expect(cash.denominations.first.value, '0.25');
    expect(cash.denominations.first.count, 4);
    expect(summary.expenses.total, 12.5);
    expect(summary.expenses.count, 2);
  });

  test('leaves closing cash and variance null on an open session', () {
    final json = sampleJson();
    json['session'] = <String, Object?>{
      ...(json['session']! as Map).cast<String, Object?>(),
      'status': 'open',
    };
    json['cash'] = <String, Object?>{
      ...(json['cash']! as Map).cast<String, Object?>(),
      'closing_cash': null,
      'cash_variance': null,
      'has_cash_variance': false,
    };

    final summary = RegisterSessionSummary.fromJson(json);
    expect(summary.status, 'open');
    expect(summary.cash.closingCash, isNull);
    expect(summary.cash.cashVariance, isNull);
    expect(summary.cash.hasCashVariance, isFalse);
  });
}
