import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/features/pos/views/payment/payment.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() {
  testWidgets('keypad entry can submit a cash payment', (tester) async {
    PaymentSheetResult? submitted;

    await _pumpPaymentSheet(
      tester,
      total: 12.5,
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

  testWidgets('wide layout exposes split tender mode without scrolling', (
    tester,
  ) async {
    await _pumpPaymentSheet(tester, total: 7, width: 1366, height: 768);

    expect(
      find.byKey(const ValueKey('payment_method_split_tender')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('payment_method_split_tender')));
    await tester.pump();

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

    await tester.tap(find.byKey(const ValueKey('payment_tender_remove_0')));
    await tester.pump();

    expect(_amountText(tester, 0), '7.00');
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
              showPrintInvoiceToggle: showPrintInvoiceToggle,
              printInvoiceAfterPayment: printInvoiceAfterPayment,
              onPrintInvoiceChanged: onPrintInvoiceChanged ?? (_) {},
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
