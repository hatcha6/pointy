import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';

void main() {
  test('parses the wallet the backend serves', () {
    final wallet = WalletOverview.fromJson({
      'available': true,
      'error': null,
      'balance': '245.500',
      'currency': 'LYD',
      'test_mode': true,
      'topups': {
        'available': true,
        'methods': [
          {
            'key': 'plutu_localbankcards',
            'gateway': 'plutu',
            'kind': 'hosted_checkout',
          },
        ],
        'min_amount': '10.00',
        'max_amount': '500.00',
        'max_decimals': 2,
        'quick_amounts': ['50', '100', 'x'],
        'pending_ttl': 1800,
      },
      'recent_topups': [
        {
          'id': 't1',
          'invoice_no': 'DFW-ABCDEFGH23',
          'method': 'plutu_localbankcards',
          'amount': '100.000',
          'status': 'paid',
          'test_mode': true,
          'requested_by': 'owner',
          'created_at': '2026-09-30T08:00:00Z',
          'paid_at': '2026-09-30T08:03:00Z',
          'record_as_expense': true,
          'expense_id': 41,
          'expense_error': '',
        },
        {
          'id': 't2',
          'invoice_no': 'DFW-PENDING234',
          'amount': '50',
          'status': 'pending',
          'checkout_url': 'https://checkout.plutus.test/pay/x',
          'created_at': '2026-09-30T09:00:00Z',
        },
      ],
      'recent_entries': [
        {
          'id': 'e1',
          'kind': 'charge',
          'service': 'sms',
          'amount': '-4.500',
          'balance_after': '245.500',
          'created_at': '2026-09-30T09:30:00Z',
        },
      ],
      'settings': {
        'record_topups_as_expenses': false,
        'expense_category': {'id': 3, 'name': 'اشتراكات'},
        'default_expense_category_name': 'خدمات دفتر',
      },
    });

    expect(wallet.available, isTrue);
    expect(wallet.balance, 245.5);
    expect(wallet.testMode, isTrue);
    expect(wallet.canTopUp, isTrue);
    expect(wallet.topUpOptions!.maxAmount, 500);
    expect(wallet.topUpOptions!.quickAmounts, [50, 100]);
    expect(wallet.topUpOptions!.pendingTtl, const Duration(minutes: 30));
    final paid = wallet.recentTopUps.first;
    expect(paid.status, WalletTopUpStatus.paid);
    expect(paid.isBookedAsExpense, isTrue);
    expect(paid.checkoutUrl, isNull);
    final pending = wallet.recentTopUps.last;
    expect(pending.status.isOpen, isTrue);
    expect(pending.checkoutUrl, 'https://checkout.plutus.test/pay/x');
    expect(pending.recordAsExpense, isNull);
    expect(wallet.recentEntries.single.amount, -4.5);
    expect(wallet.recentEntries.single.kind, WalletEntryKind.charge);
    expect(wallet.settings.recordTopUpsAsExpenses, isFalse);
    expect(wallet.settings.effectiveCategoryName, 'اشتراكات');
  });

  test('an unreachable relay reads as unavailable with its reason', () {
    final wallet = WalletOverview.fromJson({
      'available': false,
      'error': {'code': 'relay_unreachable', 'detail': 'تعذر'},
      'balance': null,
      'topups': null,
      'recent_topups': [],
      'recent_entries': [],
      'settings': {
        'record_topups_as_expenses': true,
        'expense_category': null,
        'default_expense_category_name': 'خدمات دفتر',
      },
    });
    expect(wallet.available, isFalse);
    expect(wallet.balance, isNull);
    expect(wallet.canTopUp, isFalse);
    expect(wallet.error?.code, 'relay_unreachable');
    expect(wallet.settings.effectiveCategoryName, 'خدمات دفتر');
  });

  test('a refusal carries its code, bounds and the failed top-up', () {
    final error = WalletException.fromResponse(
      422,
      '{"code":"invalid_amount","detail":"المبلغ غير مقبول.","min_amount":"10.00","max_amount":"5000.00"}',
    );
    expect(error.code, 'invalid_amount');
    expect(error.minAmount, 10);
    expect(error.maxAmount, 5000);
    expect(error.isRetryable, isFalse);

    final gateway = WalletException.fromResponse(
      502,
      '{"code":"gateway_busy","detail":"x","top_up":{"id":"t9","status":"failed","amount":"5"}}',
    );
    expect(gateway.isRetryable, isTrue);
    expect(gateway.topUp?.status, WalletTopUpStatus.failed);

    // DRF's own validation shape, and a 403 page.
    expect(
      WalletException.fromResponse(400, '{"amount":["Ensure..."]}').code,
      'invalid_amount',
    );
    expect(WalletException.fromResponse(403, '<html>').code, 'forbidden');
  });
}
