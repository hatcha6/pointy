import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';
import 'package:pointy_frontend/src/features/settings/view_models/wallet_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_section.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../wallet_view_model_test.dart';

void main() {
  late FakeWalletRepository repo;
  late List<Uri> opened;

  Future<WalletViewModel> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final viewModel = WalletViewModel(
      repo,
      launchCheckout: (uri) async {
        opened.add(uri);
        return true;
      },
      newAttemptKey: () => 'key',
      fastPollInterval: const Duration(hours: 1),
      slowPollInterval: const Duration(hours: 1),
    );
    await viewModel.load();
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
            child: WalletSection(viewModel: viewModel),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return viewModel;
  }

  setUp(() {
    repo = FakeWalletRepository();
    opened = [];
  });

  testWidgets('shows the balance, the top-up button and the books switch', (
    tester,
  ) async {
    await pump(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.textContaining('50.00'), findsWidgets);
    expect(find.text(l10n.walletTopUpButton), findsOneWidget);
    expect(find.text(l10n.walletRecordExpensesTitle), findsOneWidget);
    expect(find.text(l10n.walletNoTopUps), findsOneWidget);
    // Right to left, like every Arabic screen.
    expect(
      Directionality.of(tester.element(find.text(l10n.walletTopUpButton))),
      TextDirection.rtl,
    );
  });

  testWidgets('an unreachable wallet says why and cannot be topped up', (
    tester,
  ) async {
    repo.walletResult = Ok(
      WalletOverview.fromJson({
        'available': false,
        'error': {'code': 'relay_unreachable', 'detail': ''},
        'recent_topups': [],
        'recent_entries': [],
        'settings': {'record_topups_as_expenses': true},
      }),
    );
    await pump(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.walletUnavailableTitle), findsOneWidget);
    expect(find.text(l10n.walletErrorRelayUnreachable), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text(l10n.walletTopUpButton),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets(
    'the sheet refuses an amount under the minimum, then opens the checkout',
    (tester) async {
      final viewModel = await pump(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      await tester.tap(find.text(l10n.walletTopUpButton));
      await tester.pumpAndSettle();
      expect(find.text(l10n.walletTopUpSheetTitle), findsWidgets);

      await tester.enterText(find.byType(TextFormField), '5');
      await tester.tap(find.text(l10n.walletTopUpContinue));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          l10n.walletTopUpAmountTooSmall('').trim().split(' ').first,
        ),
        findsOneWidget,
      );
      expect(repo.starts, isEmpty);

      await tester.enterText(find.byType(TextFormField), '100');
      await tester.tap(find.text(l10n.walletTopUpContinue));
      // The waiting screen spins until a verdict, so it never "settles".
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(repo.starts.single['amount'], '100.00');
      expect(opened.single.host, 'checkout.plutus.test');
      expect(find.text(l10n.walletAwaitingTitle), findsOneWidget);
      expect(viewModel.topUpStage, WalletTopUpStage.awaitingPayment);

      // Paid while the owner was in the browser: the sheet turns by itself.
      repo.topUpResult = Ok(
        topUp(status: WalletTopUpStatus.paid, expenseId: 3),
      );
      await viewModel.checkActiveTopUp();
      await tester.pumpAndSettle();
      expect(find.text(l10n.walletPaidTitle), findsOneWidget);
      expect(find.text(l10n.walletPaidBooked('خدمات دفتر')), findsOneWidget);

      await tester.tap(find.text(l10n.walletDone));
      await tester.pumpAndSettle();
      expect(viewModel.isPolling, isFalse);
    },
  );

  testWidgets('the books switch saves the setting', (tester) async {
    final viewModel = await pump(tester);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(viewModel.recordTopUpsAsExpenses, isFalse);
  });
}
