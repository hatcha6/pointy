import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/relay_installation_status.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';

void main() {
  group('the SMS balance', () {
    test('reads the relay block and counts messages in thousandths', () {
      final sms = SmsWallet.fromJson({
        'balance': '4.500',
        'price': '0.150',
        'messages_left': 30,
        'configured': true,
        'available': true,
      });
      expect(sms.balance, 4.5);
      expect(sms.price, 0.15);
      expect(sms.messagesLeft, 30);
      expect(sms.canSend, isTrue);
      // 0.3 / 0.15 is two messages, not 1.9999.
      expect(sms.messagesFor(0.3), 2);
      expect(sms.messagesFor(20), 133);
      expect(sms.messagesFor(0.149), 0);
      expect(sms.messagesFor(0), 0);
    });

    test('an empty balance, or a provider not set up, cannot send', () {
      expect(
        SmsWallet.fromJson({'balance': '0.000', 'price': '0.150'}).canSend,
        isFalse,
      );
      expect(
        SmsWallet.fromJson({
          'balance': '9',
          'price': '0.15',
          'messages_left': 60,
          'configured': false,
        }).canSend,
        isFalse,
      );
    });

    test('below zero it owes what longer messages still cost', () {
      final owing = SmsWallet.fromJson({
        'balance': '-0.150',
        'price': '0.150',
        'messages_left': 0,
      });
      expect(owing.owed, closeTo(0.15, 1e-9));
      expect(owing.canSend, isFalse);
      expect(
        SmsWallet.fromJson({'balance': '0.300', 'price': '0.150'}).owed,
        0,
      );
    });
  });

  group('a plan', () {
    test('reads the relay block', () {
      final plan = WalletPlan.fromJson({
        'key': 'remote_access',
        'available': true,
        'price': '50.000',
        'period_days': 30,
        'max_periods': 12,
        'active': true,
        'until': '2026-11-01T09:00:00Z',
        'included': false,
      });
      expect(plan.key, WalletPlan.remoteAccess);
      expect(plan.available, isTrue);
      expect(plan.price, 50);
      expect(plan.priceFor(3), 150);
      expect(plan.until, DateTime.utc(2026, 11, 1, 9).toLocal());
    });

    test('more periods start where the plan already ends', () {
      final now = DateTime(2026, 10, 2);
      final running = WalletPlan(
        key: WalletPlan.ai,
        available: true,
        active: true,
        price: 30,
        until: DateTime(2026, 10, 20),
      );
      expect(running.endsAfter(1, now), DateTime(2026, 11, 19));
      const stopped = WalletPlan(
        key: WalletPlan.ai,
        available: true,
        active: false,
      );
      expect(stopped.endsAfter(3, now), now.add(const Duration(days: 90)));
    });

    test('a plan the wallet does not sell has no price', () {
      final plan = WalletPlan.fromJson({
        'key': 'ai',
        'available': false,
        'active': false,
      });
      expect(plan.price, isNull);
      expect(plan.priceFor(1), 0);
    });
  });

  group('the overview', () {
    test('carries the SMS balance and the plans, and a spend patches them', () {
      final overview = WalletOverview.fromJson({
        'available': true,
        'balance': '100.000',
        'sms': {'balance': '1.500', 'price': '0.150', 'messages_left': 10},
        'plans': [
          {
            'key': 'remote_access',
            'available': true,
            'price': '50',
            'active': false,
          },
          {'key': 'ai', 'available': true, 'price': '30', 'active': false},
          {'available': true},
        ],
        'recent_topups': [],
        'recent_entries': [],
      });
      expect(overview.sms?.messagesLeft, 10);
      expect(overview.plans.map((plan) => plan.key), [
        WalletPlan.remoteAccess,
        WalletPlan.ai,
      ]);

      final after = overview.copyWith(
        balance: 70,
        plan: WalletPlan(
          key: WalletPlan.ai,
          available: true,
          active: true,
          price: 30,
          until: DateTime(2026, 11, 1),
        ),
      );
      expect(after.balance, 70);
      expect(after.planFor(WalletPlan.ai)?.active, isTrue);
      expect(after.planFor(WalletPlan.remoteAccess)?.active, isFalse);
      expect(after.sms?.balance, 1.5, reason: 'untouched parts stay');
    });

    test('a relay from before the SMS balance sends neither', () {
      final overview = WalletOverview.fromJson({
        'available': true,
        'balance': '10.000',
        'recent_topups': [],
        'recent_entries': [],
      });
      expect(overview.sms, isNull);
      expect(overview.plans, isEmpty);
    });
  });

  test('a transfer on the SMS statement reads as such', () {
    final entry = WalletEntry.fromJson({
      'id': 'e1',
      'account': 'sms',
      'kind': 'transfer',
      'amount': '15.000',
      'balance_after': '15.000',
      'created_at': '2026-10-01T10:00:00Z',
    });
    expect(entry.account, WalletAccount.sms);
    expect(entry.kind, WalletEntryKind.transfer);
    expect(
      WalletEntry.fromJson({'id': 'e2', 'kind': 'topup'}).account,
      WalletAccount.main,
    );
  });

  test('a spend the wallet could not cover says what it holds', () {
    final error = WalletException.fromResponse(
      409,
      '{"code":"insufficient_balance","detail":"x","balance":"5.000","amount":"15.000"}',
    );
    expect(error.code, 'insufficient_balance');
    expect(error.balance, 5);
    expect(error.amount, 15);
    expect(error.isRetryable, isFalse);
  });

  group('the subscription status', () {
    Map<String, Object?> base() => {
      'configured': true,
      'remote_access_supported': true,
      'installation_id': 'inst',
      'relay_enabled': false,
      'subscription_active': false,
      'ai_enabled': false,
    };

    test('takes the backend\'s word on what runs and until when', () {
      final status = RelayInstallationStatus.fromJson({
        ...base(),
        'remote_access_until': '2026-11-01T09:00:00Z',
        'ai_available': true,
        'ai_until': '2026-10-20T09:00:00Z',
        'sms_available': true,
      });
      expect(status.remoteAccessUntil, DateTime.utc(2026, 11, 1, 9).toLocal());
      expect(status.aiAvailable, isTrue, reason: 'paid from the wallet');
      expect(status.smsAvailable, isTrue);
      expect(status.anyPlanActive, isTrue);
    });

    test('a backend from before the wallet is read off the flags', () {
      final status = RelayInstallationStatus.fromJson({
        ...base(),
        'subscription_active': true,
        'ai_enabled': true,
        'sms_enabled': true,
      });
      expect(status.aiAvailable, isTrue);
      expect(status.smsAvailable, isTrue);
      expect(
        RelayInstallationStatus.fromJson({
          ...base(),
          'ai_enabled': true,
        }).aiAvailable,
        isFalse,
      );
    });
  });
}
