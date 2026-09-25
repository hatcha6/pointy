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

  test('a summary from a server without provider services parses empty', () {
    final summary = RegisterSessionSummary.fromJson(sampleJson());

    expect(summary.integrations.hasActivity, isFalse);
    expect(summary.integrations.transactions, isEmpty);
    expect(summary.integrations.totals.sold, 0);
  });

  test('parses where each provider\'s money went', () {
    final json = sampleJson()
      ..['integrations'] = {
        'providers': [
          {
            'provider': 'hdbox',
            'count': 2,
            'sold': '110.00',
            'cost': '90.00',
            'margin': '20.00',
            'delivered': {'count': 1, 'amount': '30.00', 'cost': '25.00'},
            'awaiting': {'count': 1, 'amount': '80.00', 'cost': '65.00'},
            'unknown': {'count': 0, 'amount': '0.00', 'cost': '0.00'},
            'refunded': {'count': 1, 'amount': '30.00', 'cost': '25.00'},
            'refunded_after_delivery': {'count': 1, 'cost': '25.00'},
          },
        ],
        'totals': {
          'count': 2,
          'sold': '110.00',
          'cost': '90.00',
          'margin': '20.00',
          'delivered': {'count': 1, 'amount': '30.00', 'cost': '25.00'},
          'awaiting': {'count': 1, 'amount': '80.00', 'cost': '65.00'},
          'unknown': {'count': 0, 'amount': '0.00', 'cost': '0.00'},
          'refunded': {'count': 1, 'amount': '30.00', 'cost': '25.00'},
          'refunded_after_delivery': {'count': 1, 'cost': '25.00'},
        },
        'transactions': [
          {
            'id': 11,
            'provider': 'hdbox',
            'kind': 'recharge',
            'order_id': 41,
            'receipt_number': 'R-41',
            'sold_at': '2026-06-24T09:12:00Z',
            'subscriber_ref': '210906803499',
            'subscriber_label': 'Ahmed',
            'option_label': '1 month',
            'price': '30.00',
            'cost': '25.00',
            'refunded_amount': '30.00',
            'status': 'confirmed',
            'bucket': 'refunded',
            'error_code': '',
            'provider_reference': '558032',
          },
          {
            'id': 12,
            'provider': 'hdbox',
            'order_id': 42,
            'price': '80.00',
            'cost': '65.00',
            'status': 'pending',
            'bucket': 'awaiting',
            'error_code': 'insufficient_float',
          },
        ],
      };

    final integrations = RegisterSessionSummary.fromJson(json).integrations;

    expect(integrations.hasActivity, isTrue);
    final hdbox = integrations.providers.single;
    expect(hdbox.provider, 'hdbox');
    expect(hdbox.sold, 110);
    expect(hdbox.cost, 90);
    expect(hdbox.margin, 20);
    expect(hdbox.awaiting.amount, 80);
    expect(hdbox.refundedAfterDelivery.count, 1);
    expect(hdbox.refundedAfterDelivery.cost, 25);
    // Kept sales plus the one given back.
    expect(hdbox.transactionCount, 3);
    expect(hdbox.needsAttention, isTrue);
    expect(integrations.totals.provider, isEmpty);

    final refunded = integrations.transactions.first;
    expect(refunded.orderId, 41);
    expect(refunded.soldAt, DateTime.utc(2026, 6, 24, 9, 12));
    expect(refunded.bucket, SessionIntegrationBucket.refunded);
    expect(refunded.refundedAmount, 30);
    // The float paid for a sale the shop gave back.
    expect(refunded.isRefundedAfterDelivery, isTrue);
    expect(integrations.transactions.last.errorCode, 'insufficient_float');
    expect(integrations.transactionsFor('hdbox'), hasLength(2));
    expect(integrations.transactionsFor('lnet'), isEmpty);
  });

  test('an unfamiliar bucket code never reads as delivered', () {
    expect(
      SessionIntegrationBucket.fromJson('something_new'),
      SessionIntegrationBucket.awaiting,
    );
    expect(
      SessionIntegrationBucket.fromJson('delivered'),
      SessionIntegrationBucket.delivered,
    );
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
