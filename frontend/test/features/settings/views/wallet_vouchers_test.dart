import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';
import 'package:pointy_frontend/src/features/settings/view_models/wallet_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_history_page.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_presentation.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_section.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import '../wallet_view_model_test.dart';

/// «رصيد الكروت»: what the till's «كروت دفتر» are paid from, filled by moving
/// money out of the main wallet exactly like the SMS balance.
void main() {
  late FakeWalletRepository repo;
  late AppLocalizations l10n;

  const enabled = VoucherWallet(balance: 50, enabled: true);

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  setUp(() {
    repo = FakeWalletRepository();
  });

  Future<WalletViewModel> pump(
    WidgetTester tester,
    Widget Function(WalletViewModel wallet) child,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final wallet = WalletViewModel(
      repo,
      newAttemptKey: () => 'key',
      fastPollInterval: const Duration(hours: 1),
      slowPollInterval: const Duration(hours: 1),
    );
    addTearDown(wallet.dispose);
    await wallet.load();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: PointyTheme.light(),
        builder: (context, inner) => PointyNavigationRailScope(
          isActive: false,
          controller: PointyNavigationRailController(),
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: SingleChildScrollView(child: child(wallet))),
      ),
    );
    await tester.pumpAndSettle();
    return wallet;
  }

  group('the card', () {
    testWidgets('sits in the wallet once the cards are switched on', (
      tester,
    ) async {
      repo.walletResult = Ok(overview(balance: 100, vouchers: enabled));
      await pump(tester, (wallet) => WalletSection(viewModel: wallet));

      expect(
        find.byKey(const ValueKey('wallet_voucher_balance')),
        findsOneWidget,
      );
      expect(find.text(l10n.walletVouchersBalanceTitle), findsOneWidget);
      // What the balance is for, said where it is shown.
      expect(find.text(l10n.walletVouchersSummary), findsOneWidget);
      expect(find.text(formatWalletMoney(50)), findsOneWidget);
    });

    testWidgets('is not there while the owner has not switched them on', (
      tester,
    ) async {
      repo.walletResult = Ok(
        overview(balance: 100, vouchers: const VoucherWallet(balance: 0)),
      );
      await pump(tester, (wallet) => WalletSection(viewModel: wallet));
      expect(
        find.byKey(const ValueKey('wallet_voucher_balance')),
        findsNothing,
      );
    });

    testWidgets('a relay with no cards of its own shows no card', (
      tester,
    ) async {
      repo.walletResult = Ok(overview(balance: 100));
      await pump(tester, (wallet) => WalletSection(viewModel: wallet));
      expect(
        find.byKey(const ValueKey('wallet_voucher_balance')),
        findsNothing,
      );
    });

    testWidgets('a company not ready to sell takes no transfer', (
      tester,
    ) async {
      repo.walletResult = Ok(
        overview(
          balance: 100,
          vouchers: const VoucherWallet(
            balance: 0,
            enabled: true,
            configured: false,
          ),
        ),
      );
      await pump(tester, (wallet) => WalletSection(viewModel: wallet));
      expect(find.text(l10n.walletVouchersNotReady), findsOneWidget);
      final allocate = tester.widget<ButtonStyleButton>(
        find.byKey(const ValueKey('wallet_voucher_allocate')),
      );
      expect(allocate.onPressed, isNull);
    });
  });

  group('the transfer', () {
    testWidgets('checks the amount, moves it, and says so', (tester) async {
      repo.walletResult = Ok(overview(balance: 100, vouchers: enabled));
      await pump(tester, (wallet) => WalletSection(viewModel: wallet));

      await tester.tap(find.byKey(const ValueKey('wallet_voucher_allocate')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.walletVouchersAllocateTitle), findsWidgets);

      final field = find.byKey(const ValueKey('voucher_allocation_amount'));
      final confirm = find.byKey(const ValueKey('voucher_allocation_confirm'));
      await tester.enterText(field, '150');
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(find.text(l10n.walletVouchersAllocateTooMuch), findsOneWidget);
      expect(repo.voucherAllocations, isEmpty, reason: 'nothing sent yet');

      await tester.enterText(field, '100');
      await tester.pumpAndSettle();
      // What the voucher balance will hold, before anything is sent.
      expect(
        find.text(l10n.walletVouchersAllocateAfter(formatWalletMoney(150))),
        findsOneWidget,
      );
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(repo.voucherAllocations.single['amount'], '100');
      expect(
        find.byKey(const ValueKey('voucher_allocation_amount')),
        findsNothing,
      );
      expect(
        find.text(l10n.walletVouchersAllocateDone(formatWalletMoney(100))),
        findsOneWidget,
      );
    });

    testWidgets('an empty wallet is sent to top up first', (tester) async {
      repo.walletResult = Ok(overview(balance: 0, vouchers: enabled));
      await pump(tester, (wallet) => WalletSection(viewModel: wallet));

      await tester.tap(find.byKey(const ValueKey('wallet_voucher_allocate')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.walletSpendTopUpFirstTitle), findsOneWidget);
      expect(
        find.byKey(const ValueKey('voucher_allocation_amount')),
        findsNothing,
      );
      final confirm = tester.widget<ButtonStyleButton>(
        find.byKey(const ValueKey('voucher_allocation_confirm')),
      );
      expect(confirm.onPressed, isNull);
    });

    testWidgets('a refusal stays in the sheet, in Arabic', (tester) async {
      repo
        ..walletResult = Ok(overview(balance: 100, vouchers: enabled))
        ..voucherAllocationResult = Error(
          const WalletException(
            code: 'vouchers_unconfigured',
            message: '',
            statusCode: 503,
          ),
        );
      await pump(tester, (wallet) => WalletSection(viewModel: wallet));
      await tester.tap(find.byKey(const ValueKey('wallet_voucher_allocate')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('voucher_allocation_amount')),
        '20',
      );
      await tester.tap(
        find.byKey(const ValueKey('voucher_allocation_confirm')),
      );
      await tester.pumpAndSettle();

      expect(find.text(l10n.walletVouchersNotReady), findsOneWidget);
      expect(
        find.byKey(const ValueKey('voucher_allocation_amount')),
        findsOneWidget,
      );
    });
  });

  group('the view model', () {
    test('moves money in, shows both balances at once and reloads', () async {
      repo.walletResult = Ok(overview(balance: 100, vouchers: enabled));
      final wallet = WalletViewModel(repo);
      await wallet.load();
      final loads = repo.walletLoads;

      expect(await wallet.spending.allocateToVouchers(50), isTrue);
      expect(repo.voucherAllocations.single['amount'], '50');
      expect(wallet.overview?.balance, 50);
      expect(wallet.overview?.vouchers?.balance, 150);
      await pumpEventQueue();
      expect(repo.walletLoads, loads + 1);
    });

    test(
      'a lost answer retries with the same key; SMS keeps its own',
      () async {
        repo
          ..walletResult = Ok(overview(balance: 100, vouchers: enabled))
          ..voucherAllocationResult = Error(
            const WalletException(code: 'relay_unreachable', message: ''),
          );
        final wallet = WalletViewModel(repo);
        await wallet.load();

        await wallet.spending.allocateToVouchers(40);
        await wallet.spending.allocateToVouchers(40);
        expect(
          repo.voucherAllocations[0]['key'],
          repo.voucherAllocations[1]['key'],
        );
        expect(repo.voucherAllocations[0]['key'], startsWith('app-vouchers-'));
        await wallet.spending.allocateToSms(40);
        expect(
          repo.allocations.single['key'],
          isNot(repo.voucherAllocations[0]['key']),
          reason: 'another balance is another transfer',
        );
      },
    );

    test('reads the voucher statement page by page', () async {
      repo
        ..walletResult = Ok(overview(vouchers: enabled))
        ..entryPages.addAll([
          Ok(
            WalletPage(
              items: [
                WalletEntry(
                  id: 'v2',
                  account: WalletAccount.vouchers,
                  kind: WalletEntryKind.charge,
                  service: 'vouchers',
                  amount: -128,
                  balanceAfter: 122,
                  createdAt: DateTime(2026, 10, 7, 9),
                ),
              ],
              hasMore: true,
            ),
          ),
          Error(Exception('offline')),
        ]);
      final wallet = WalletViewModel(repo);
      await wallet.load();

      await wallet.spending.loadVoucherEntries(reset: true);
      expect(wallet.spending.voucherEntries.single.id, 'v2');
      expect(repo.entryAccounts.single, WalletAccount.vouchers);

      await wallet.spending.loadVoucherEntries();
      expect(wallet.spending.voucherEntriesFailed, isTrue);
      expect(
        wallet.spending.voucherEntriesHasMore,
        isTrue,
        reason: 'a failed page must not end the list',
      );
    });
  });

  testWidgets('the history gets a tab for the voucher balance', (tester) async {
    repo
      ..walletResult = Ok(overview(vouchers: enabled))
      ..topUpPages.add(const Ok(WalletPage(items: [], hasMore: false)))
      ..entryPages.addAll([
        const Ok(WalletPage(items: [], hasMore: false)),
        Ok(
          WalletPage(
            items: [
              WalletEntry(
                id: 'v1',
                account: WalletAccount.vouchers,
                kind: WalletEntryKind.transfer,
                amount: 250,
                balanceAfter: 250,
                createdAt: DateTime(2026, 10, 6, 9),
                description: 'تحويل من المحفظة',
              ),
            ],
            hasMore: false,
          ),
        ),
      ]);
    await pump(
      tester,
      (wallet) =>
          SizedBox(height: 900, child: WalletHistoryPage(viewModel: wallet)),
    );

    expect(find.text(l10n.walletHistoryVouchersTab), findsOneWidget);
    expect(repo.entryAccounts, [WalletAccount.main, WalletAccount.vouchers]);
    await tester.tap(find.text(l10n.walletHistoryVouchersTab));
    await tester.pumpAndSettle();
    expect(find.text('تحويل من المحفظة'), findsOneWidget);
  });
}
