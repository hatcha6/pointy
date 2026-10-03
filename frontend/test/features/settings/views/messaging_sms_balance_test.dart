import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/messaging_gateway.dart';
import 'package:pointy_frontend/src/data/models/messaging_status.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';
import 'package:pointy_frontend/src/data/repositories/messaging_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/messaging_settings_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/wallet_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/messaging_presentation.dart';
import 'package:pointy_frontend/src/features/settings/views/messaging_settings_page.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../wallet_view_model_test.dart';

/// The SMS page when messages are paid from the SMS balance: an empty balance
/// says how to fill it and can be filled from right there; a funded one says
/// how many messages it still pays for.
void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));

  Future<MessagingSettingsViewModel> pump(
    WidgetTester tester,
    _PrepaidRepo repo, {
    WalletViewModel? wallet,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final viewModel = MessagingSettingsViewModel(repo, wallet: wallet);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: MessagingSettingsPage(viewModel: viewModel),
      ),
    );
    await tester.pumpAndSettle();
    return viewModel;
  }

  testWidgets('an empty balance stops the sending, not the shop\'s brakes', (
    tester,
  ) async {
    final viewModel = await pump(tester, _PrepaidRepo(balance: 0));
    expect(viewModel.serviceState, MessagingServiceState.noBalance);
    expect(find.text(l10n.messagingStatusNoBalance), findsOneWidget);
    expect(find.text(l10n.messagingBalanceEmptyTitle), findsOneWidget);
    expect(find.text(l10n.messagingBalanceTitle), findsOneWidget);
    // The dials stay the shop's to set; only a test send needs money.
    expect(find.text(l10n.messagingServiceSwitchLabel), findsOneWidget);
    expect(find.text(l10n.messagingTestSendButton), findsNothing);
    // Without a wallet on the page there is nothing to move money from.
    expect(find.byKey(const ValueKey('messaging_allocate')), findsNothing);
  });

  testWidgets('the balance is filled from the page and read again', (
    tester,
  ) async {
    final walletRepo = FakeWalletRepository()
      ..walletResult = Ok(
        overview(
          balance: 20,
          sms: const SmsWallet(balance: 0, price: 0.15, messagesLeft: 0),
        ),
      );
    final wallet = WalletViewModel(walletRepo, newAttemptKey: () => 'key');
    final repo = _PrepaidRepo(balance: 0);
    await pump(tester, repo, wallet: wallet);
    final loadsBefore = repo.loads;

    await tester.ensureVisible(
      find.byKey(const ValueKey('messaging_allocate')),
    );
    await tester.tap(find.byKey(const ValueKey('messaging_allocate')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('sms_allocation_amount')),
      '15',
    );
    await tester.tap(find.byKey(const ValueKey('sms_allocation_confirm')));
    await tester.pumpAndSettle();

    expect(walletRepo.allocations.single['amount'], '15');
    expect(repo.loads, greaterThan(loadsBefore), reason: 're-read after');
  });

  testWidgets('a funded balance says what it still pays for', (tester) async {
    final viewModel = await pump(tester, _PrepaidRepo(balance: 4.5));
    expect(viewModel.serviceState, MessagingServiceState.active);
    expect(find.text(l10n.messagingBalanceEmptyTitle), findsNothing);
    expect(find.textContaining(l10n.walletSmsMessagesLeft(30)), findsOneWidget);
    expect(find.text(l10n.messagingBalanceSentThisMonth(12)), findsOneWidget);
    // Paid by length: the page says what one SMS holds.
    expect(find.text(l10n.walletSmsLengthNote), findsOneWidget);
    // No brake set: no meter against a cap.
    expect(find.text(l10n.messagingUsageSentLabel), findsNothing);
  });

  testWidgets('a balance below zero says what it owes', (tester) async {
    // A message went out longer than it was held for: the shop owes the
    // difference, and the next transfer pays it first.
    final viewModel = await pump(tester, _PrepaidRepo(balance: -0.15));
    expect(viewModel.serviceState, MessagingServiceState.noBalance);
    expect(find.text(l10n.walletSmsOwed('0.15 د.ل')), findsOneWidget);
    expect(find.textContaining(l10n.walletSmsMessagesLeft(0)), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the company\'s monthly brake shows as the usual meter', (
    tester,
  ) async {
    await pump(tester, _PrepaidRepo(balance: 4.5, limit: 100));
    expect(find.text(l10n.messagingUsageSentLabel), findsOneWidget);
  });

  test('a message refused for money is named in Arabic', () {
    expect(
      messagingErrorMessage('insufficient_balance', l10n),
      l10n.messagingErrorInsufficientBalance,
    );
  });
}

class _PrepaidRepo extends MessagingRepository {
  _PrepaidRepo({required this.balance, this.limit = 0})
    : super(PosApiService());

  final double balance;
  final int limit;
  int loads = 0;

  @override
  Future<Result<MessagingServiceStatus>> loadStatus() async {
    loads++;
    const gateway = MessagingGateway(
      id: 1,
      name: 'رسائل دفتر',
      isDefault: true,
    );
    final canSend = balance >= 0.15;
    return Ok(
      MessagingServiceStatus(
        entitled: canSend,
        available: canSend,
        gateway: gateway,
        smsWallet: SmsWallet(
          balance: balance,
          price: 0.15,
          messagesLeft: balance <= 0 ? 0 : (balance * 1000).round() ~/ 150,
        ),
        usage: MessagingUsage(
          used: 12,
          limit: limit,
          remaining: limit == 0 ? -1 : limit - 12,
        ),
      ),
    );
  }
}
