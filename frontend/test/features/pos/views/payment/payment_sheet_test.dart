import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/features/pos/views/payment/payment.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() {
  testWidgets('wide keypad entry can submit a cash payment', (tester) async {
    PaymentSheetResult? submitted;

    await _pumpPaymentSheet(
      tester,
      total: 12.5,
      width: 1366,
      height: 768,
      onSubmit: (result) => submitted = result,
    );

    await _tapKey(tester, 'payment_keypad_clear');
    await _tapKey(tester, 'payment_keypad_digit_1');
    await _tapKey(tester, 'payment_keypad_digit_2');
    await _tapKey(tester, 'payment_keypad_decimal');
    await _tapKey(tester, 'payment_keypad_digit_5');

    expect(_amountText(tester, 0), '12.5');

    await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
    await tester.pump();

    expect(submitted?.payments.single.method, PaymentMethod.cash);
    expect(submitted?.payments.single.amount, 12.5);
  });

  testWidgets('compact checkout omits the keypad', (tester) async {
    await _pumpPaymentSheet(tester, total: 12.5);

    expect(find.byKey(const ValueKey('payment_keypad_digit_1')), findsNothing);
    expect(find.byKey(const ValueKey('payment_keypad_clear')), findsNothing);
    expect(
      find.byKey(const ValueKey('payment_tender_amount_0')),
      findsOneWidget,
    );
  });

  testWidgets('quick cash amounts show change and apply only the sale total', (
    tester,
  ) async {
    PaymentSheetResult? submitted;

    await _pumpPaymentSheet(
      tester,
      total: 7,
      onSubmit: (result) => submitted = result,
    );

    await _tapKey(tester, 'payment_quick_amount_round_up_0');

    expect(_amountText(tester, 0), '10.00');
    expect(find.text('3.00 د.ل'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
    await tester.pump();

    expect(submitted?.payments.single.method, PaymentMethod.cash);
    expect(submitted?.payments.single.amount, 7);
  });

  testWidgets('confirm is disabled when no payment methods are enabled', (
    tester,
  ) async {
    await _pumpPaymentSheet(
      tester,
      enableCash: false,
      enableCard: false,
      enableTransfer: false,
    );

    expect(
      find.text('لا توجد طريقة دفع مفعلة. راجع إعدادات المتجر.'),
      findsWidgets,
    );
    final confirm = tester.widget<FilledButton>(
      find.byKey(const ValueKey('payment_confirm_button')),
    );
    expect(confirm.onPressed, isNull);
  });

  testWidgets('receipt toggle updates independently from payment validity', (
    tester,
  ) async {
    bool? printInvoice;
    PaymentSheetResult? submitted;

    await _pumpPaymentSheet(
      tester,
      showPrintInvoiceToggle: true,
      printInvoiceAfterPayment: false,
      onPrintInvoiceChanged: (value) => printInvoice = value,
      onSubmit: (result) => submitted = result,
    );

    await _tapKey(tester, 'payment_receipt_toggle');

    expect(printInvoice, isTrue);

    await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
    await tester.pump();

    expect(submitted?.payments.single.method, PaymentMethod.cash);
  });

  testWidgets('payment method availability selects the first enabled method', (
    tester,
  ) async {
    PaymentSheetResult? submitted;

    await _pumpPaymentSheet(
      tester,
      enableCash: false,
      enableCard: true,
      enableTransfer: false,
      onSubmit: (result) => submitted = result,
    );

    expect(find.byKey(const ValueKey('payment_method_cash')), findsNothing);
    expect(find.byKey(const ValueKey('payment_method_card')), findsWidgets);
    expect(
      find.byKey(const ValueKey('payment_quick_amount_exact')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
    await tester.pump();

    expect(submitted?.payments.single.method, PaymentMethod.card);
  });

  testWidgets('split tender removal rebalances the remaining tender', (
    tester,
  ) async {
    PaymentSheetResult? submitted;

    await _pumpPaymentSheet(
      tester,
      total: 7,
      onSubmit: (result) => submitted = result,
    );

    await _tapKey(tester, 'payment_add_tender');
    await tester.enterText(
      find.byKey(const ValueKey('payment_tender_amount_0')),
      '5.00',
    );
    await tester.pump();

    expect(_amountText(tester, 1), '2.00');

    await _tapKey(tester, 'payment_tender_remove_0');

    expect(_amountText(tester, 0), '7.00');

    await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
    await tester.pump();

    expect(submitted?.payments.single.method, PaymentMethod.card);
    expect(submitted?.payments.single.amount, 7);
  });

  testWidgets(
    'split tender uses the add-payment button, not a fourth segment',
    (tester) async {
      await _pumpPaymentSheet(tester, total: 7, width: 1366, height: 768);

      // Splitting is an explicit action, not a crowded fourth method segment.
      expect(
        find.byKey(const ValueKey('payment_method_split_tender')),
        findsNothing,
      );

      await _tapKey(tester, 'payment_add_tender');

      expect(
        find.byKey(const ValueKey('payment_tender_amount_1')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('payment_tender_amount_0')),
        '5.00',
      );
      await tester.pump();

      expect(_amountText(tester, 1), '2.00');

      await _tapKey(tester, 'payment_tender_remove_0');

      expect(_amountText(tester, 0), '7.00');
    },
  );

  testWidgets('credit sale accepts a partial down-payment', (tester) async {
    PaymentSheetResult? submitted;

    await _pumpPaymentSheet(
      tester,
      total: 10,
      onSubmit: (result) => submitted = result,
    );

    await tester.tap(find.byKey(const ValueKey('sale_type_credit')));
    await tester.pump();

    // Credit starts with no payment line; add a down-payment, then tender less
    // than the total so the remainder becomes the customer balance.
    await tester.tap(find.byKey(const ValueKey('payment_add_tender')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('payment_tender_amount_0')),
      '4.00',
    );
    await tester.pump();

    expect(find.text('المتبقّي على العميل'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
    await tester.pump();

    expect(submitted?.saleType, SaleType.credit);
    expect(submitted?.payments.single.amount, 4);
  });

  testWidgets('credit sale can be fully on credit with no tender', (
    tester,
  ) async {
    PaymentSheetResult? submitted;

    await _pumpPaymentSheet(
      tester,
      total: 10,
      onSubmit: (result) => submitted = result,
    );

    await tester.tap(find.byKey(const ValueKey('sale_type_credit')));
    await tester.pump();

    // Selecting credit removes the payment line by default — the sale is fully
    // on the customer's account, with no tender to fill in.
    expect(find.byKey(const ValueKey('payment_tender_amount_0')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
    await tester.pump();

    expect(submitted?.saleType, SaleType.credit);
    expect(submitted?.payments, isEmpty);
  });

  testWidgets(
    'credit down-payment line can be removed (back to fully on credit)',
    (tester) async {
      PaymentSheetResult? submitted;

      await _pumpPaymentSheet(
        tester,
        total: 10,
        onSubmit: (result) => submitted = result,
      );

      await tester.tap(find.byKey(const ValueKey('sale_type_credit')));
      await tester.pump();

      // Add a down-payment line, then remove it even though it's the only line —
      // the reported bug was that a debt sale's payment line was unremovable.
      await tester.tap(find.byKey(const ValueKey('payment_add_tender')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('payment_tender_amount_0')),
        '4.00',
      );
      await tester.pump();

      // Credit is selected and the line is removable even as the only tender.
      expect(find.text('المتبقّي على العميل'), findsOneWidget);
      final removeFinder = find.byKey(
        const ValueKey('payment_tender_remove_0'),
      );
      expect(tester.widget<IconButton>(removeFinder).onPressed, isNotNull);

      await tester.ensureVisible(removeFinder);
      await tester.pump();
      await tester.tap(removeFinder);
      await tester.pump();

      expect(
        find.byKey(const ValueKey('payment_tender_amount_0')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
      await tester.pump();

      expect(submitted?.saleType, SaleType.credit);
      expect(submitted?.payments, isEmpty);
    },
  );

  testWidgets(
    'removing one of two credit down-payment lines keeps the other intact',
    (tester) async {
      // Wide layout so both tender rows render on-screen (mirrors the standard
      // split-tender test).
      await _pumpPaymentSheet(tester, total: 10, width: 1366, height: 900);

      await tester.tap(find.byKey(const ValueKey('sale_type_credit')));
      await tester.pump();

      // Two down-payment slices: 3 + 4 (7 of the 10 total; rest on account).
      await _tapKey(tester, 'payment_add_tender');
      await tester.enterText(
        find.byKey(const ValueKey('payment_tender_amount_0')),
        '3.00',
      );
      await tester.pump();
      await _tapKey(tester, 'payment_add_tender');
      final amount1 = find.byKey(const ValueKey('payment_tender_amount_1'));
      await tester.ensureVisible(amount1);
      await tester.enterText(amount1, '4.00');
      await tester.pump();

      // Remove the first slice. The survivor must KEEP its 4.00 — the bug
      // re-balanced the remaining line up to the full 10.00 total, turning a
      // down-payment into a full payment.
      await _tapKey(tester, 'payment_tender_remove_0');

      expect(_amountText(tester, 0), '4.00');
    },
  );

  testWidgets('quotation hides the keypad and takes no payment', (
    tester,
  ) async {
    PaymentSheetResult? submitted;

    await _pumpPaymentSheet(
      tester,
      total: 10,
      width: 1366,
      height: 768,
      onSubmit: (result) => submitted = result,
    );

    await tester.tap(find.byKey(const ValueKey('sale_type_quotation')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('payment_keypad_digit_1')), findsNothing);
    expect(find.byKey(const ValueKey('payment_tender_amount_0')), findsNothing);
    expect(
      find.byKey(const ValueKey('quotation_reserve_stock_toggle')),
      findsOneWidget,
    );
    // The stock-hold date picker only appears once a hold is requested.
    expect(
      find.byKey(const ValueKey('quotation_valid_until_picker')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('quotation_reserve_stock_toggle')),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('quotation_valid_until_picker')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
    await tester.pump();

    expect(submitted?.saleType, SaleType.quotation);
    expect(submitted?.payments, isEmpty);
    expect(submitted?.reserveStock, isTrue);
    expect(submitted?.validUntil, isNotNull);
  });

  testWidgets('credit sale blocks confirm when a customer is required', (
    tester,
  ) async {
    await _pumpPaymentSheet(
      tester,
      total: 10,
      hasCustomer: false,
      requireCustomerForCredit: true,
    );

    await tester.tap(find.byKey(const ValueKey('sale_type_credit')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('sale_customer_required_banner')),
      findsOneWidget,
    );
    final confirm = tester.widget<FilledButton>(
      find.byKey(const ValueKey('payment_confirm_button')),
    );
    expect(confirm.onPressed, isNull);
  });

  testWidgets('credit/quotation segments hidden when shop disables them', (
    tester,
  ) async {
    await _pumpPaymentSheet(
      tester,
      enableCredit: false,
      enableQuotations: false,
    );

    expect(find.byKey(const ValueKey('sale_type_standard')), findsNothing);
    expect(find.byKey(const ValueKey('sale_type_credit')), findsNothing);
    expect(find.byKey(const ValueKey('sale_type_quotation')), findsNothing);
  });
}

Future<void> _pumpPaymentSheet(
  WidgetTester tester, {
  double total = 7,
  double width = 390,
  bool enableCash = true,
  bool enableCard = true,
  bool enableTransfer = true,
  bool showPrintInvoiceToggle = false,
  bool printInvoiceAfterPayment = false,
  ValueChanged<bool>? onPrintInvoiceChanged,
  ValueChanged<PaymentSheetResult>? onSubmit,
  bool hasCustomer = false,
  bool requireCustomerForCredit = false,
  bool enableQuotations = true,
  bool enableCredit = true,
  double height = 844,
}) async {
  tester.view.physicalSize = Size(width, height);
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
              enableCashPayments: enableCash,
              enableCardPayments: enableCard,
              enableTransferPayments: enableTransfer,
              requireCardReceipt: false,
              trustedCardTerminalIds: const [],
              showPrintInvoiceToggle: showPrintInvoiceToggle,
              printInvoiceAfterPayment: printInvoiceAfterPayment,
              onPrintInvoiceChanged: onPrintInvoiceChanged ?? (_) {},
              showShareInvoiceToggle: false,
              shareInvoiceAfterPayment: false,
              onShareInvoiceChanged: (_) {},
              hasCustomer: hasCustomer,
              requireCustomerForCredit: requireCustomerForCredit,
              enableQuotations: enableQuotations,
              enableCredit: enableCredit,
              onSubmit: onSubmit ?? (_) {},
              onCancel: () {},
            ),
          ),
        ),
      ),
    ),
  );
}

String _amountText(WidgetTester tester, int index) {
  final field = tester.widget<TextField>(
    find.byKey(ValueKey('payment_tender_amount_$index')),
  );
  return field.controller!.text;
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}
