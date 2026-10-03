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
            'key': 'dafa_moamalat',
            'gateway': 'dafa',
            'provider': 'moamalat',
            'kind': 'hosted_page',
            'payer': '',
            'birth_year': false,
          },
          {
            'key': 'dafa_sadad',
            'gateway': 'dafa',
            'provider': 'sadad',
            'kind': 'otp',
            'payer': 'phone',
            'birth_year': true,
          },
          {
            'key': 'dafa_sahara_pay',
            'gateway': 'dafa',
            'provider': 'sahara-pay',
            'kind': 'otp',
            'payer': 'card',
            'birth_year': false,
          },
          {'gateway': 'dafa', 'kind': 'otp'},
        ],
        'min_amount': '10.00',
        'max_amount': '500.00',
        'max_decimals': 2,
        'quick_amounts': ['50', '100', 'x'],
        'pending_ttl': 1800,
        'max_otp_attempts': 5,
      },
      'recent_topups': [
        {
          'id': 't1',
          'invoice_no': 'DFW-ABCDEFGH23',
          'method': 'dafa_sadad',
          'kind': 'otp',
          'payer_hint': '091•••678',
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
          'method': 'dafa_moamalat',
          'kind': 'hosted_page',
          'checkout_url': 'https://pay.dafa.test/x',
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
    final options = wallet.topUpOptions!;
    expect(options.maxAmount, 500);
    expect(options.maxDecimals, 2);
    expect(options.maxOtpAttempts, 5);
    expect(options.quickAmounts, [50, 100]);
    expect(options.pendingTtl, const Duration(minutes: 30));
    expect(
      options.methods.map((method) => method.key),
      ['dafa_moamalat', 'dafa_sadad', 'dafa_sahara_pay'],
      reason: 'a method without a key is dropped',
    );
    final cards = options.methods[0];
    final sadad = options.methods[1];
    final sahara = options.methods[2];
    expect(cards.confirmsWithCode, isFalse);
    expect(cards.payer, WalletPayer.none);
    expect(sadad.confirmsWithCode, isTrue);
    expect(sadad.payer, WalletPayer.phone);
    expect(sadad.needsBirthYear, isTrue);
    expect(sahara.payer, WalletPayer.card);
    expect(sahara.provider, 'sahara-pay');
    final paid = wallet.recentTopUps.first;
    expect(paid.status, WalletTopUpStatus.paid);
    expect(paid.isBookedAsExpense, isTrue);
    expect(paid.checkoutUrl, isNull);
    expect(paid.payerHint, '091•••678');
    expect(paid.kind, 'otp');
    final pending = wallet.recentTopUps.last;
    expect(pending.status.isOpen, isTrue);
    expect(pending.checkoutUrl, 'https://pay.dafa.test/x');
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

  test('a refused code carries the gateway\'s word and the tries left', () {
    final wrong = WalletException.fromResponse(
      422,
      '{"code":"otp_rejected","detail":"رمز التحقق غير صحيح. أعد إدخاله.",'
      '"gateway_code":"PAYER_OTP_WRONG","gateway_message":"رمز التحقق غير صحيح، يرجى إعادة إدخاله.",'
      '"attempts_left":4,"top_up":{"id":"t1","status":"pending","kind":"otp","otp_attempts_left":4}}',
    );
    expect(wrong.code, 'otp_rejected');
    expect(wrong.gatewayCode, 'PAYER_OTP_WRONG');
    expect(wrong.gatewayMessage, contains('رمز التحقق'));
    expect(wrong.attemptsLeft, 4);
    expect(wrong.leavesCodeOpen, isTrue);
    expect(wrong.topUp?.otpAttemptsLeft, 4);

    final declined = WalletException.fromResponse(
      422,
      '{"code":"declined","gateway_code":"PAYER_INSUFFICIENT_FUNDS"}',
    );
    expect(declined.leavesCodeOpen, isFalse);
  });

  test('a start says what comes next, a confirm whether to keep asking', () {
    final code = WalletTopUpStart.fromJson({
      'top_up': {'id': 't1', 'status': 'pending', 'kind': 'otp'},
      'next_action': 'otp',
      'checkout_url': '',
      'replayed': false,
    });
    expect(code.needsCode, isTrue);
    final page = WalletTopUpStart.fromJson({
      'top_up': {'id': 't2', 'status': 'pending', 'kind': 'hosted_page'},
      'next_action': 'hosted_page',
      'checkout_url': 'https://pay.dafa.test/t2',
    });
    expect(page.needsCode, isFalse);
    // A backend from before the field: the top-up's own kind decides.
    final older = WalletTopUpStart.fromJson({
      'top_up': {'id': 't3', 'status': 'pending', 'kind': 'otp'},
    });
    expect(older.needsCode, isTrue);

    final waiting = WalletTopUpConfirmation.fromJson({
      'top_up': {'id': 't1', 'status': 'pending'},
      'code': 'awaiting_gateway',
    });
    expect(waiting.awaitingGateway, isTrue);
    final paid = WalletTopUpConfirmation.fromJson({
      'top_up': {'id': 't1', 'status': 'paid'},
      'code': '',
    });
    expect(paid.awaitingGateway, isFalse);
    expect(paid.topUp.status, WalletTopUpStatus.paid);
  });

  test('a relay from before Dafa still offers its card checkout', () {
    final method = WalletTopUpMethod.fromJson({
      'key': 'plutu_localbankcards',
      'gateway': 'plutu',
      'kind': 'hosted_checkout',
    });
    expect(method.confirmsWithCode, isFalse);
    expect(method.payer, WalletPayer.none);
  });

  test('the payer\'s details are read the way the relay reads them', () {
    for (final (raw, want) in [
      ('0912345678', '912345678'),
      ('+218 92 345 6789', '923456789'),
      ('00218941234567', '941234567'),
      ('٠٩١٢٣٤٥٦٧٨', '912345678'),
      ('091-234-5678', '912345678'),
      ('0213334444', null),
      ('91234567', null),
      ('0912345678x', null),
    ]) {
      expect(WalletPayerRules.phone(raw), want, reason: raw);
    }
    expect(WalletPayerRules.card('6395 0438 3518 0860'), '6395043835180860');
    expect(WalletPayerRules.card('12345'), isNull);
    expect(WalletPayerRules.code(' ١١١١١١ '), '111111');
    expect(WalletPayerRules.code('123'), isNull);
    final now = DateTime(2026, 10, 1);
    expect(WalletPayerRules.birthYear('1990', now), '1990');
    expect(WalletPayerRules.birthYear('٢٠٠١', now), '2001');
    expect(WalletPayerRules.birthYear('2031', now), isNull);
    expect(WalletPayerRules.birthYear('90', now), isNull);
  });
}
