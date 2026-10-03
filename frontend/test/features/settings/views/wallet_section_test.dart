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
      expect(repo.starts.single['amount'], '100');
      expect(repo.starts.single['method'], 'dafa_moamalat');
      expect(opened.single.host, 'pay.dafa.test');
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

  Finder inDialog(Finder finder) =>
      find.descendant(of: find.byType(AlertDialog), matching: finder);

  testWidgets(
    'a phone wallet asks for the number in a dialog, then the code, and pays',
    (tester) async {
      repo.startResult = codeStart();
      final viewModel = await pump(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      await tester.tap(find.text(l10n.walletTopUpButton));
      await tester.pumpAndSettle();

      await tester.tap(find.text(l10n.walletMethodSadad));
      await tester.pumpAndSettle();
      expect(find.text(l10n.walletTopUpCodeNote), findsOneWidget);
      // The form asks only for the amount: the payer comes after "pay".
      expect(find.byType(TextFormField), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '100');
      await tester.tap(find.text(l10n.walletTopUpContinue));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(l10n.walletPayerDialogTitle('سداد')), findsOneWidget);
      final fields = inDialog(find.byType(TextFormField));
      expect(fields, findsNWidgets(2), reason: 'phone and birth year');
      await tester.enterText(fields.at(0), '0812345678');
      await tester.enterText(fields.at(1), '1990');
      await tester.tap(inDialog(find.text(l10n.walletTopUpSendCode)));
      await tester.pumpAndSettle();
      expect(find.text(l10n.walletPayerPhoneInvalid), findsOneWidget);
      expect(repo.starts, isEmpty, reason: 'refused before any round trip');

      await tester.enterText(fields.at(0), '0912345678');
      await tester.tap(inDialog(find.text(l10n.walletTopUpSendCode)));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(repo.starts.single['payer'], '0912345678');
      expect(repo.starts.single['birth'], '1990');
      expect(repo.starts.single['amount'], '100');
      expect(viewModel.topUpStage, WalletTopUpStage.awaitingCode);
      expect(find.text(l10n.walletCodeTitle), findsOneWidget);
      expect(opened, isEmpty);

      // A wrong code: said in place, with the tries left.
      repo.confirmResult = Error(
        WalletException(
          code: 'otp_rejected',
          message: '',
          attemptsLeft: 4,
          topUp: sadadTopUp(),
        ),
      );
      await tester.enterText(find.byType(TextFormField), '123456');
      await tester.tap(find.text(l10n.walletCodeConfirm));
      await tester.pumpAndSettle();
      expect(
        find.text('${l10n.walletCodeWrong} ${l10n.walletCodeAttemptsLeft(4)}'),
        findsOneWidget,
      );

      repo.confirmResult = Ok(
        WalletTopUpConfirmation(
          topUp: sadadTopUp(status: WalletTopUpStatus.paid, expenseId: 4),
          awaitingGateway: false,
        ),
      );
      await tester.enterText(find.byType(TextFormField), '111111');
      await tester.tap(find.text(l10n.walletCodeConfirm));
      await tester.pumpAndSettle();
      expect(repo.codes, ['123456', '111111']);
      expect(find.text(l10n.walletPaidTitle), findsOneWidget);
    },
  );

  testWidgets(
    'a number the provider refuses keeps the dialog open with its words',
    (tester) async {
      repo.startResult = Error(
        const WalletException(
          code: 'payer_rejected',
          message: '',
          gatewayMessage: 'الرقم غير مشترك في خدمة سداد.',
        ),
      );
      final viewModel = await pump(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      await tester.tap(find.text(l10n.walletTopUpButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.walletMethodSadad));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '100');
      await tester.tap(find.text(l10n.walletTopUpContinue));
      await tester.pumpAndSettle();
      final fields = inDialog(find.byType(TextFormField));
      await tester.enterText(fields.at(0), '0912345678');
      await tester.enterText(fields.at(1), '1990');
      await tester.tap(inDialog(find.text(l10n.walletTopUpSendCode)));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget, reason: 'fix it here');
      expect(
        inDialog(find.text('الرقم غير مشترك في خدمة سداد.')),
        findsOneWidget,
      );
      expect(
        find.text('الرقم غير مشترك في خدمة سداد.'),
        findsOneWidget,
        reason: 'said once, in the dialog, not again on the form behind',
      );

      // Fixed and sent again: the payment starts and the dialog goes.
      repo.startResult = codeStart();
      await tester.enterText(fields.at(0), '0923456789');
      await tester.tap(inDialog(find.text(l10n.walletTopUpSendCode)));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(viewModel.topUpStage, WalletTopUpStage.awaitingCode);
      expect(repo.starts.last['payer'], '0923456789');

      // "Change details" calls the payment off and the dialog opens again
      // filled in.
      await tester.tap(find.text(l10n.walletCodeChangeDetails));
      await tester.pumpAndSettle();
      expect(repo.cancels, ['topup-1']);
      await tester.tap(find.text(l10n.walletTopUpContinue));
      await tester.pumpAndSettle();
      expect(inDialog(find.text('0923456789')), findsOneWidget);
      expect(inDialog(find.text('1990')), findsOneWidget);
    },
  );

  testWidgets('a refused amount closes the dialog and the form says why', (
    tester,
  ) async {
    repo.startResult = Error(
      const WalletException(code: 'amount_not_allowed', message: ''),
    );
    await pump(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await tester.tap(find.text(l10n.walletTopUpButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.walletMethodSadad));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '100');
    await tester.tap(find.text(l10n.walletTopUpContinue));
    await tester.pumpAndSettle();
    final fields = inDialog(find.byType(TextFormField));
    await tester.enterText(fields.at(0), '0912345678');
    await tester.enterText(fields.at(1), '1990');
    await tester.tap(inDialog(find.text(l10n.walletTopUpSendCode)));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(l10n.walletErrorGatewayAmount), findsOneWidget);
  });

  testWidgets('a declined payment says so in the gateway\'s words', (
    tester,
  ) async {
    repo.startResult = codeStart();
    repo.confirmResult = Error(
      WalletException(
        code: 'declined',
        message: '',
        gatewayMessage: 'تعذّر إتمام العملية، يرجى مراجعة المصرف.',
        topUp: sadadTopUp(
          status: WalletTopUpStatus.failed,
          errorCode: 'declined',
        ),
      ),
    );
    final viewModel = await pump(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await tester.tap(find.text(l10n.walletTopUpButton));
    await tester.pumpAndSettle();
    viewModel.selectMethod('dafa_sadad');
    await viewModel.startTopUp(
      100,
      userIdentifier: '0912345678',
      birthYear: '1990',
    );
    await viewModel.confirmCode('222222');
    await tester.pumpAndSettle();
    expect(find.text(l10n.walletDeclinedTitle), findsOneWidget);
    expect(
      find.text('تعذّر إتمام العملية، يرجى مراجعة المصرف.'),
      findsOneWidget,
    );
  });

  testWidgets('the books switch saves the setting', (tester) async {
    final viewModel = await pump(tester);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(viewModel.recordTopUpsAsExpenses, isFalse);
  });
}
