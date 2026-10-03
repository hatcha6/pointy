import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';
import 'package:pointy_frontend/src/features/settings/view_models/wallet_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_presentation.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_section.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_spend_rows.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../wallet_view_model_test.dart';

void main() {
  late FakeWalletRepository repo;
  late AppLocalizations l10n;

  const emptySms = SmsWallet(balance: 0, price: 0.15, messagesLeft: 0);

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  setUp(() {
    repo = FakeWalletRepository();
  });

  Future<WalletViewModel> pump(
    WidgetTester tester,
    Widget Function(WalletViewModel wallet) child, {
    Size size = const Size(800, 1400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final wallet = WalletViewModel(
      repo,
      newAttemptKey: () => 'key',
      fastPollInterval: const Duration(hours: 1),
      slowPollInterval: const Duration(hours: 1),
    );
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
        home: Scaffold(
          body: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: Listenable.merge([wallet, wallet.spending]),
              builder: (_, _) => child(wallet),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return wallet;
  }

  group('the SMS balance', () {
    testWidgets('sits in the wallet, empty, with the transfer that fills it', (
      tester,
    ) async {
      repo.walletResult = Ok(overview(balance: 100, sms: emptySms));
      await pump(tester, (wallet) => WalletSection(viewModel: wallet));
      expect(find.text(l10n.walletSmsBalanceTitle), findsOneWidget);
      expect(
        find.textContaining(l10n.walletSmsMessagesLeft(0)),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('wallet_sms_allocate')), findsOneWidget);
    });

    testWidgets('a wallet from before the SMS balance shows no card', (
      tester,
    ) async {
      repo.walletResult = Ok(overview(balance: 100));
      await pump(tester, (wallet) => WalletSection(viewModel: wallet));
      expect(find.byKey(const ValueKey('wallet_sms_balance')), findsNothing);
    });

    testWidgets('the transfer checks the amount, then moves it and says so', (
      tester,
    ) async {
      repo.walletResult = Ok(overview(balance: 20, sms: emptySms));
      var refreshed = 0;
      await pump(
        tester,
        (wallet) =>
            WalletSection(viewModel: wallet, onSpent: () => refreshed++),
      );
      await tester.tap(find.byKey(const ValueKey('wallet_sms_allocate')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.walletSmsAllocateTitle), findsWidgets);

      final field = find.byKey(const ValueKey('sms_allocation_amount'));
      final confirm = find.byKey(const ValueKey('sms_allocation_confirm'));
      await tester.enterText(field, '25');
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(find.text(l10n.walletSmsAllocateTooMuch), findsOneWidget);
      await tester.enterText(field, '0.1');
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.walletSmsAllocateTooLittle(formatWalletMoney(0.15))),
        findsOneWidget,
      );
      expect(repo.allocations, isEmpty, reason: 'nothing is sent until valid');

      await tester.enterText(field, '15');
      await tester.pumpAndSettle();
      // How many messages the amount pays for, before it is sent.
      expect(find.text(l10n.walletSmsMessagesLeft(100)), findsOneWidget);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(repo.allocations.single['amount'], '15');
      expect(find.byKey(const ValueKey('sms_allocation_amount')), findsNothing);
      expect(
        find.text(l10n.walletSmsAllocateDone(formatWalletMoney(15))),
        findsOneWidget,
      );
      expect(refreshed, 1);
    });

    testWidgets('a wallet that cannot pay for one message is sent to top up', (
      tester,
    ) async {
      repo.walletResult = Ok(overview(balance: 0.1, sms: emptySms));
      await pump(tester, (wallet) => WalletSection(viewModel: wallet));
      await tester.tap(find.byKey(const ValueKey('wallet_sms_allocate')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.walletSpendTopUpFirstTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('sms_allocation_amount')), findsNothing);
      final confirm = tester.widget<ButtonStyleButton>(
        find.byKey(const ValueKey('sms_allocation_confirm')),
      );
      expect(confirm.onPressed, isNull);
    });
  });

  group('a plan', () {
    WalletPlan aiPlan({bool active = false, DateTime? until}) => WalletPlan(
      key: WalletPlan.ai,
      available: true,
      active: active,
      price: 30,
      until: until,
    );

    testWidgets('its row says what a month costs and offers to pay', (
      tester,
    ) async {
      repo.walletResult = Ok(overview(balance: 100, plans: [aiPlan()]));
      await pump(
        tester,
        (wallet) => WalletPlanRow(
          wallet: wallet,
          plan: wallet.overview!.planFor(WalletPlan.ai)!,
        ),
      );
      expect(find.textContaining('30.00'), findsOneWidget);
      expect(find.text(l10n.walletPlanBuyButton), findsOneWidget);
    });

    testWidgets('the sheet prices the length chosen and pays for it', (
      tester,
    ) async {
      repo.walletResult = Ok(overview(balance: 100, plans: [aiPlan()]));
      var purchased = 0;
      await pump(
        tester,
        (wallet) => WalletPlanRow(
          wallet: wallet,
          plan: wallet.overview!.planFor(WalletPlan.ai)!,
          onPurchased: () => purchased++,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('wallet_plan_buy_ai')));
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.walletPlanSheetTitle(l10n.walletPlanAiTitle)),
        findsWidgets,
      );
      await tester.tap(find.byKey(const ValueKey('plan_periods_3')));
      await tester.pumpAndSettle();
      // Three months is 90.00 out of the wallet's 100.00, leaving 10.00.
      expect(find.text(l10n.walletPlanPayButton('90.00 د.ل')), findsOneWidget);
      expect(find.textContaining('10.00'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('plan_pay')));
      await tester.pumpAndSettle();
      expect(repo.purchases.single, containsPair('periods', 3));
      expect(find.byKey(const ValueKey('plan_pay')), findsNothing);
      expect(purchased, 1);
    });

    testWidgets('a length the wallet cannot cover cannot be paid', (
      tester,
    ) async {
      repo.walletResult = Ok(overview(balance: 50, plans: [aiPlan()]));
      await pump(
        tester,
        (wallet) => WalletPlanRow(
          wallet: wallet,
          plan: wallet.overview!.planFor(WalletPlan.ai)!,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('wallet_plan_buy_ai')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('plan_periods_3')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.walletSpendTopUpFirstTitle), findsOneWidget);
      final pay = tester.widget<ButtonStyleButton>(
        find.byKey(const ValueKey('plan_pay')),
      );
      expect(pay.onPressed, isNull);
      // One month fits again.
      await tester.tap(find.byKey(const ValueKey('plan_periods_1')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.walletSpendTopUpFirstTitle), findsNothing);
    });

    testWidgets('a refusal stays in the sheet in Arabic', (tester) async {
      repo.walletResult = Ok(overview(balance: 100, plans: [aiPlan()]));
      repo.purchaseResult = Error(
        const WalletException(
          code: 'plan_unavailable',
          message: '',
          statusCode: 422,
        ),
      );
      await pump(
        tester,
        (wallet) => WalletPlanRow(
          wallet: wallet,
          plan: wallet.overview!.planFor(WalletPlan.ai)!,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('wallet_plan_buy_ai')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('plan_pay')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.walletErrorPlanUnavailable), findsOneWidget);
      expect(find.byKey(const ValueKey('plan_pay')), findsOneWidget);
    });

    testWidgets('a renewal says the days are added after the current end', (
      tester,
    ) async {
      repo.walletResult = Ok(
        overview(
          balance: 100,
          plans: [
            aiPlan(
              active: true,
              until: DateTime.now().add(const Duration(days: 10)),
            ),
          ],
        ),
      );
      await pump(
        tester,
        (wallet) => WalletPlanRow(
          wallet: wallet,
          plan: wallet.overview!.planFor(WalletPlan.ai)!,
        ),
      );
      expect(find.text(l10n.walletPlanRenewButton), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('wallet_plan_buy_ai')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.walletPlanRenewNote), findsOneWidget);
    });
  });
}
