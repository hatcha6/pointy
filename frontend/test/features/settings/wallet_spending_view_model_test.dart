import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';
import 'package:pointy_frontend/src/features/settings/view_models/wallet_view_model.dart';

import 'wallet_view_model_test.dart';

void main() {
  late FakeWalletRepository repo;
  late WalletViewModel wallet;

  const sms = SmsWallet(balance: 0, price: 0.15, messagesLeft: 0);
  final aiPlan = WalletPlan(
    key: WalletPlan.ai,
    available: true,
    active: false,
    price: 30,
  );

  setUp(() async {
    repo = FakeWalletRepository()
      ..walletResult = Ok(overview(balance: 100, sms: sms, plans: [aiPlan]));
    wallet = WalletViewModel(repo, newAttemptKey: () => 'key');
    await wallet.load();
  });

  group('money into the SMS balance', () {
    test('moves it, shows both balances at once and reloads', () async {
      final loadsBefore = repo.walletLoads;
      final moved = await wallet.spending.allocateToSms(15);
      expect(moved, isTrue);
      expect(repo.allocations.single['amount'], '15');
      expect(wallet.overview?.balance, 85);
      expect(wallet.overview?.sms?.messagesLeft, 100);
      expect(wallet.spending.allocationError, isNull);
      await pumpEventQueue();
      expect(repo.walletLoads, loadsBefore + 1);
    });

    test(
      'a refusal is kept for the sheet, and a new try gets a new key',
      () async {
        repo.allocationResult = Error(
          const WalletException(
            code: 'insufficient_balance',
            message: '',
            statusCode: 409,
            balance: 5,
            amount: 15,
          ),
        );
        expect(await wallet.spending.allocateToSms(15), isFalse);
        expect(wallet.spending.allocationError?.code, 'insufficient_balance');
        expect(wallet.overview?.balance, 100, reason: 'nothing moved');
        await wallet.spending.allocateToSms(15);
        expect(
          repo.allocations[0]['key'],
          isNot(repo.allocations[1]['key']),
          reason: 'a refusal is an answer: trying again is a new transfer',
        );
        wallet.spending.beginAllocation();
        expect(wallet.spending.allocationError, isNull);
      },
    );

    test(
      'a lost answer is retried with the same key, so it moves once',
      () async {
        repo.allocationResult = Error(
          const WalletException(code: 'relay_unreachable', message: ''),
        );
        await wallet.spending.allocateToSms(15);
        await wallet.spending.allocateToSms(15);
        expect(repo.allocations[0]['key'], repo.allocations[1]['key']);
        await wallet.spending.allocateToSms(20);
        expect(
          repo.allocations[2]['key'],
          isNot(repo.allocations[1]['key']),
          reason: 'another amount is another transfer',
        );
      },
    );

    test('amounts go out with the dirham\'s three places at most', () async {
      await wallet.spending.allocateToSms(1.255);
      expect(repo.allocations.single['amount'], '1.255');
    });
  });

  group('a plan', () {
    test('paying patches the plan and the balance, and reloads', () async {
      final bought = await wallet.spending.purchasePlan(WalletPlan.ai, 1);
      expect(bought?.active, isTrue);
      expect(repo.purchases.single, containsPair('plan', 'ai'));
      expect(repo.purchases.single, containsPair('periods', 1));
      expect(wallet.overview?.balance, 70);
      expect(wallet.overview?.planFor(WalletPlan.ai)?.active, isTrue);
      expect(wallet.spending.isPurchasing, isFalse);
    });

    test('a refusal names the reason and buys nothing', () async {
      repo.purchaseResult = Error(
        const WalletException(
          code: 'plan_included',
          message: '',
          statusCode: 409,
        ),
      );
      expect(await wallet.spending.purchasePlan(WalletPlan.ai, 3), isNull);
      expect(wallet.spending.purchaseError?.code, 'plan_included');
      expect(wallet.overview?.planFor(WalletPlan.ai)?.active, isFalse);
    });
  });

  test('the SMS statement pages through the SMS account', () async {
    repo.entryPages.addAll([
      Ok(
        WalletPage(
          items: [
            WalletEntry(
              id: 's1',
              account: WalletAccount.sms,
              kind: WalletEntryKind.charge,
              amount: -0.15,
              balanceAfter: 4.35,
              createdAt: DateTime(2026, 10, 1),
            ),
          ],
          hasMore: true,
        ),
      ),
      Error(Exception('offline')),
    ]);
    await wallet.spending.loadSmsEntries(reset: true);
    expect(wallet.spending.smsEntries, hasLength(1));
    expect(repo.entryAccounts.single, WalletAccount.sms);
    await wallet.spending.loadSmsEntries();
    expect(wallet.spending.smsEntriesFailed, isTrue);
    expect(
      wallet.spending.smsEntriesHasMore,
      isTrue,
      reason: 'a failed page keeps "more" on, so the next scroll retries it',
    );
  });
}
