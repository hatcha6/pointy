import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';
import 'package:pointy_frontend/src/features/settings/view_models/wallet_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_top_up_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import 'wallet_view_model_test.dart';

void main() {
  group('the gateway fee', () {
    test('is read from the relay and rounded up to the dirham', () {
      final options = WalletOverview.fromJson({
        'available': true,
        'balance': '0.000',
        'topups': {
          'available': true,
          'methods': const [],
          'min_amount': '10.00',
          'max_amount': '5000.00',
          'fee_percent': '2.00',
        },
      }).topUpOptions!;
      expect(options.feePercent, 2);
      expect(options.feeFor(100, sadad), 2);
      expect(options.feeFor(10.01, sadad), 0.201);
      expect(options.feeFor(12.34, sadad), 0.247);
      expect(
        options.feeFor(100, WalletTopUpMethod.bankTransferMethod),
        0,
        reason: 'a bank transfer keeps no fee',
      );
    });

    test('a relay from before the fee keeps none', () {
      final options = overview().topUpOptions!;
      expect(options.feeFor(100, sadad), 0);
      final old = WalletTopUp.fromJson({'id': 't', 'amount': '100.000'});
      expect((old.fee, old.creditAmount), (0.0, 100.0));
    });

    test('a started top-up carries what the wallet gets', () {
      final started = WalletTopUp.fromJson({
        'id': 't',
        'amount': '100.000',
        'fee': '2.000',
        'credit_amount': '98.000',
      });
      expect(
        (started.amount, started.fee, started.creditAmount),
        (100.0, 2.0, 98.0),
      );
    });
  });

  group('the top-up form', () {
    Future<WalletViewModel> pumpForm(
      WidgetTester tester, {
      double feePercent = 2,
      String method = 'dafa_sadad',
      double? initialAmount = 100,
    }) async {
      final repo = FakeWalletRepository()
        ..walletResult = Ok(
          overview(
            feePercent: feePercent,
            methods: const [
              bankCards,
              sadad,
              yussor,
              WalletTopUpMethod.bankTransferMethod,
            ],
          ),
        );
      final viewModel = WalletViewModel(
        repo,
        launchCheckout: (_) async => true,
        newAttemptKey: () => 'fee-test',
        fastPollInterval: const Duration(hours: 1),
        slowPollInterval: const Duration(hours: 1),
      );
      addTearDown(viewModel.dispose);
      await viewModel.load();
      viewModel
        ..beginTopUp()
        ..selectMethod(method);
      await tester.binding.setSurfaceSize(const Size(430, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
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
          home: Scaffold(
            body: Material(
              child: WalletTopUpFlow(
                viewModel: viewModel,
                initialAmount: initialAmount,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return viewModel;
    }

    testWidgets('shows what the wallet gets before paying', (tester) async {
      await pumpForm(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      expect(find.text(l10n.walletFeeCreditLabel), findsOneWidget);
      expect(find.text(l10n.walletFeeLabel('2')), findsOneWidget);
      expect(find.text('98.00 $currencySymbol'), findsOneWidget);
      expect(find.text('\u2066−2.00\u2069 $currencySymbol'), findsOneWidget);

      // It follows the amount as it is typed.
      await tester.enterText(find.byType(TextFormField), '50');
      await tester.pump();
      expect(find.text('49.00 $currencySymbol'), findsOneWidget);

      // Nothing valid typed: it says a fee applies, without figures.
      await tester.enterText(find.byType(TextFormField), '');
      await tester.pump();
      expect(find.text(l10n.walletFeeEmptyHint('2')), findsOneWidget);
      expect(find.text(l10n.walletFeeCreditLabel), findsNothing);
    });

    testWidgets('a bank transfer shows no fee', (tester) async {
      await pumpForm(tester, method: WalletTopUpMethod.bankTransfer);
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      expect(find.text(l10n.walletFeeTitle), findsNothing);
    });

    testWidgets('a relay without a fee shows none', (tester) async {
      await pumpForm(tester, feePercent: 0);
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      expect(find.text(l10n.walletFeeTitle), findsNothing);
    });
  });
}
