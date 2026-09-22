import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/money_position.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/features/pos/views/payment/payment.dart';
import 'package:pointy_frontend/src/shared/barcode/barcode_scan_listener.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../../support/moamalat_receipt_links.dart';

/// Which bank a card or transfer lands in, chosen at the till.
///
/// The rule these are written against is that checkout must not change for the
/// shops that have not asked for this. Every install is seeded with one generic
/// bank account, so "has a bank account" cannot be the trigger — an owner
/// having *identified* one is.
void main() {
  group('the control stays out of the way', () {
    testWidgets('a shop with the seeded, unidentified account sees no picker', (
      tester,
    ) async {
      await _pumpSheet(tester, bankAccounts: [_account(id: 1, name: 'المصرف')]);

      await _selectCard(tester);

      expect(
        find.byKey(const ValueKey('payment_bank_account_single')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('payment_bank_account_field')),
        findsNothing,
      );
    });

    testWidgets('a shop with no accounts at all sees no picker', (
      tester,
    ) async {
      await _pumpSheet(tester);

      await _selectCard(tester);

      expect(
        find.byKey(const ValueKey('payment_bank_account_single')),
        findsNothing,
      );
    });

    testWidgets('and sends no account, so the server routes as it always did', (
      tester,
    ) async {
      PaymentSheetResult? submitted;
      await _pumpSheet(
        tester,
        bankAccounts: [_account(id: 1, name: 'المصرف')],
        onSubmit: (result) => submitted = result,
      );

      await _selectCard(tester);
      await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
      await tester.pump();

      expect(submitted!.payments.single.moneyAccountId, isNull);
    });

    testWidgets('cash never names a bank even when two accounts exist', (
      tester,
    ) async {
      PaymentSheetResult? submitted;
      await _pumpSheet(
        tester,
        bankAccounts: _twoBanks(),
        onSubmit: (result) => submitted = result,
      );

      await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
      await tester.pump();

      expect(submitted!.payments.single.method, PaymentMethod.cash);
      expect(submitted!.payments.single.moneyAccountId, isNull);
    });
  });

  group('two banks', () {
    testWidgets('a card tender offers the choice and defaults to the default', (
      tester,
    ) async {
      PaymentSheetResult? submitted;
      await _pumpSheet(
        tester,
        bankAccounts: _twoBanks(),
        onSubmit: (result) => submitted = result,
      );

      await _selectCard(tester);

      expect(
        find.byKey(const ValueKey('payment_bank_account_field')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
      await tester.pump();

      expect(submitted!.payments.single.moneyAccountId, 1);
    });

    testWidgets('a single identified account is stated and still travels', (
      tester,
    ) async {
      PaymentSheetResult? submitted;
      await _pumpSheet(
        tester,
        bankAccounts: [
          _account(
            id: 7,
            name: 'الجمهورية',
            bankSlug: 'jbank',
            isDefault: true,
          ),
        ],
        onSubmit: (result) => submitted = result,
      );

      await _selectCard(tester);

      expect(
        find.byKey(const ValueKey('payment_bank_account_single')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
      await tester.pump();

      // Pinned, not left blank: an untagged payment follows whichever account
      // is default TODAY, so a shop that later adds a second bank and makes it
      // the default would otherwise watch a year of takings change banks.
      expect(submitted!.payments.single.moneyAccountId, 7);
    });
  });

  group('the terminal chooses for the cashier', () {
    testWidgets('a scanned slip routes to the account its machine feeds', (
      tester,
    ) async {
      PaymentSheetResult? submitted;
      final accounts = _twoBanks();
      await _pumpSheet(
        tester,
        total: 25,
        bankAccounts: accounts,
        accountForTerminal: (terminalId) =>
            terminalId == '9XQQPL42' ? accounts[1] : null,
        onSubmit: (result) => submitted = result,
      );

      await _selectCard(tester);
      _scan(tester, moamalatReceiptUrl(amount: 25, terminalId: '9XQQPL42'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('payment_bank_account_auto')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
      await tester.pump();

      expect(submitted!.payments.single.moneyAccountId, 2);
    });

    testWidgets('an unmapped machine leaves the default alone', (tester) async {
      PaymentSheetResult? submitted;
      await _pumpSheet(
        tester,
        total: 25,
        bankAccounts: _twoBanks(),
        accountForTerminal: (_) => null,
        onSubmit: (result) => submitted = result,
      );

      await _selectCard(tester);
      _scan(tester, moamalatReceiptUrl(amount: 25, terminalId: 'UNKNOWN1'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('payment_bank_account_auto')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
      await tester.pump();

      expect(submitted!.payments.single.moneyAccountId, 1);
    });

    testWidgets('a cashier who picked a bank is not overruled by a scan', (
      tester,
    ) async {
      PaymentSheetResult? submitted;
      final accounts = _twoBanks();
      await _pumpSheet(
        tester,
        total: 25,
        bankAccounts: accounts,
        accountForTerminal: (_) => accounts[1],
        onSubmit: (result) => submitted = result,
      );

      await _selectCard(tester);
      // The cashier reaches for the dropdown and names the second bank
      // themselves; the slip that follows names it too, so nothing visibly
      // changes — what is under test is that the "chosen by terminal" note
      // does NOT appear, because no machine made this decision.
      await _chooseAccount(tester, accounts[1].id);
      _scan(tester, moamalatReceiptUrl(amount: 25, terminalId: '9XQQPL42'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('payment_bank_account_auto')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
      await tester.pump();

      expect(submitted!.payments.single.moneyAccountId, 2);
    });

    testWidgets('switching the line to cash drops the terminal note', (
      tester,
    ) async {
      final accounts = _twoBanks();
      await _pumpSheet(
        tester,
        total: 25,
        bankAccounts: accounts,
        accountForTerminal: (_) => accounts[1],
      );

      await _selectCard(tester);
      _scan(tester, moamalatReceiptUrl(amount: 25, terminalId: '9XQQPL42'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('payment_bank_account_auto')),
        findsOneWidget,
      );

      // The slip goes back with the method, and so does the bank it chose:
      // a line with no receipt must not keep claiming a bank on its authority.
      await _tapMethodChip(tester, 'cash');

      expect(
        find.byKey(const ValueKey('payment_bank_account_auto')),
        findsNothing,
      );
    });
  });
}

List<MoneyAccount> _twoBanks() => [
  _account(id: 1, name: 'الجمهورية', bankSlug: 'jbank', isDefault: true),
  _account(id: 2, name: 'الأمان', bankSlug: 'aman'),
];

MoneyAccount _account({
  required int id,
  required String name,
  String bankSlug = '',
  bool isDefault = false,
}) {
  return MoneyAccount(
    id: id,
    name: name,
    kind: MoneyAccountKind.bank,
    bankSlug: bankSlug,
    isDefault: isDefault,
  );
}

Future<void> _selectCard(WidgetTester tester) => _tapMethodChip(tester, 'card');

Future<void> _tapMethodChip(WidgetTester tester, String method) async {
  final finder = find.byKey(ValueKey('payment_method_$method'));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _chooseAccount(WidgetTester tester, int accountId) async {
  final field = tester.widget<DropdownButtonFormField<int?>>(
    find.byKey(const ValueKey('payment_bank_account_field')),
  );
  field.onChanged!(accountId);
  await tester.pumpAndSettle();
}

void _scan(WidgetTester tester, String value) {
  tester
      .widget<BarcodeScanListener>(find.byType(BarcodeScanListener))
      .onBarcodeScanned(value);
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  double total = 7,
  List<MoneyAccount> bankAccounts = const [],
  MoneyAccount? Function(String terminalId)? accountForTerminal,
  ValueChanged<PaymentSheetResult>? onSubmit,
}) async {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

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
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: SizedBox.expand(
            child: PaymentSheet(
              total: total,
              enableCashPayments: true,
              enableCardPayments: true,
              enableTransferPayments: true,
              requireCardReceipt: false,
              trustedCardTerminalIds: const [],
              bankAccounts: bankAccounts,
              accountForTerminal: accountForTerminal,
              showPrintInvoiceToggle: false,
              printInvoiceAfterPayment: false,
              onPrintInvoiceChanged: (_) {},
              showShareInvoiceToggle: false,
              shareInvoiceAfterPayment: false,
              onShareInvoiceChanged: (_) {},
              onSubmit: onSubmit ?? (_) {},
              onCancel: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
