import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/features/companion/companion_bridge.dart';
import 'package:pointy_frontend/src/features/companion/companion_scope.dart';
import 'package:pointy_frontend/src/features/pos/views/payment/payment.dart';
import 'package:pointy_frontend/src/shared/barcode/barcode_scan_listener.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../../support/fake_companion_bridge.dart';
import '../../../../support/moamalat_receipt_links.dart';

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

  testWidgets('credit sale carries the due date picked from a preset', (
    tester,
  ) async {
    PaymentSheetResult? submitted;

    await _pumpPaymentSheet(
      tester,
      total: 10,
      width: 1366,
      height: 900,
      onSubmit: (result) => submitted = result,
    );

    await tester.tap(find.byKey(const ValueKey('sale_type_credit')));
    await tester.pump();

    // The due-date picker is offered for a debt sale.
    expect(
      find.byKey(const ValueKey('credit_due_date_picker')),
      findsOneWidget,
    );

    // One tap on the "+ a week" chip sets the due date to today + 7 days.
    final weekChip = find.byKey(const ValueKey('credit_due_date_preset_7'));
    await tester.ensureVisible(weekChip);
    await tester.tap(weekChip);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
    await tester.pump();

    expect(submitted?.saleType, SaleType.credit);
    final now = DateTime.now();
    final expected = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 7));
    // A credit invoice's due date rides in its own field now; `validUntil`
    // means only a quotation's expiry.
    expect(submitted?.dueDate, expected);
    expect(submitted?.validUntil, isNull);
  });

  testWidgets('credit sale proposes the agreed term without a tap', (
    tester,
  ) async {
    final proposed = DateTime(2026, 10, 10);
    PaymentSheetResult? submitted;
    await _pumpPaymentSheet(
      tester,
      total: 10,
      width: 1366,
      height: 900,
      proposedDueDate: proposed,
      onSubmit: (result) => submitted = result,
    );

    await tester.tap(find.byKey(const ValueKey('sale_type_credit')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
    await tester.pump();

    expect(submitted?.dueDate, proposed);
  });

  testWidgets('clearing the proposed term leaves an open tab', (tester) async {
    // The distinction the API depends on: a cleared field is an instruction to
    // record no due date, not a request to fall back to the customer's terms.
    PaymentSheetResult? submitted;
    await _pumpPaymentSheet(
      tester,
      total: 10,
      width: 1366,
      height: 900,
      proposedDueDate: DateTime(2026, 10, 10),
      onSubmit: (result) => submitted = result,
    );

    await tester.tap(find.byKey(const ValueKey('sale_type_credit')));
    await tester.pump();
    await _tapKey(tester, 'credit_due_date_clear');
    await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
    await tester.pump();

    expect(submitted?.saleType, SaleType.credit);
    expect(submitted?.dueDate, isNull);
  });

  testWidgets('switching away from credit drops the proposed term', (
    tester,
  ) async {
    PaymentSheetResult? submitted;
    await _pumpPaymentSheet(
      tester,
      total: 10,
      width: 1366,
      height: 900,
      proposedDueDate: DateTime(2026, 10, 10),
      onSubmit: (result) => submitted = result,
    );

    await tester.tap(find.byKey(const ValueKey('sale_type_credit')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sale_type_standard')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
    await tester.pump();

    expect(submitted?.saleType, SaleType.standard);
    expect(submitted?.dueDate, isNull);
  });

  testWidgets('the due-date picker is credit-only', (tester) async {
    await _pumpPaymentSheet(tester, total: 10, width: 1366, height: 900);

    // Standard sale: no due date.
    expect(find.byKey(const ValueKey('credit_due_date_picker')), findsNothing);

    // Quotation carries a stock-hold deadline instead, not a credit due date.
    await tester.tap(find.byKey(const ValueKey('sale_type_quotation')));
    await tester.pump();
    expect(find.byKey(const ValueKey('credit_due_date_picker')), findsNothing);
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

  testWidgets('a receipt scanned into the sheet matches the card payment '
      'without opening the dialog', (tester) async {
    PaymentSheetResult? submitted;
    await _pumpPaymentSheet(
      tester,
      total: 45,
      requireCardReceipt: true,
      trustedCardTerminalIds: const ['0JA8Y13W'],
      onSubmit: (result) => submitted = result,
    );

    await tester.tap(find.byKey(const ValueKey('payment_method_card')));
    await tester.pumpAndSettle();
    expect(find.text('هذه الدفعة تحتاج مسح إيصال البطاقة.'), findsOneWidget);

    _scanIntoSheet(tester, moamalatReceiptUrl(amount: 45));
    await tester.pump();

    // No dialog was opened, and the payment is matched exactly as if one had
    // been: the sale can be confirmed and carries the receipt.
    expect(find.byKey(const ValueKey('card_receipt_url_field')), findsNothing);
    expect(find.textContaining('تمت المطابقة'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
    await tester.pump();

    expect(submitted?.payments.single.method, PaymentMethod.card);
    expect(
      submitted?.payments.single.cardReceiptUrl,
      moamalatReceiptUrl(amount: 45),
      reason: 'the scanned slip is what the sale is sent with',
    );
  });

  testWidgets('anything that is not a receipt link is left alone', (
    tester,
  ) async {
    await _pumpPaymentSheet(
      tester,
      total: 45,
      requireCardReceipt: true,
      trustedCardTerminalIds: const ['0JA8Y13W'],
    );

    await tester.tap(find.byKey(const ValueKey('payment_method_card')));
    await tester.pumpAndSettle();

    // A product barcode, a loyalty card, a stray QR: none of them may say
    // anything about a payment — not even an error.
    _scanIntoSheet(tester, '6291041500213');
    _scanIntoSheet(tester, 'https://example.com/whatever');
    await tester.pump();

    expect(find.textContaining('تمت المطابقة'), findsNothing);
    expect(
      find.byKey(const ValueKey('payment_scan_receipt_error')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('payment_scan_pending_receipt')),
      findsNothing,
    );
  });

  testWidgets('a receipt from a terminal the shop does not own is refused', (
    tester,
  ) async {
    await _pumpPaymentSheet(
      tester,
      total: 45,
      requireCardReceipt: true,
      trustedCardTerminalIds: const ['0JA8Y13W'],
    );

    await tester.tap(find.byKey(const ValueKey('payment_method_card')));
    await tester.pumpAndSettle();

    _scanIntoSheet(
      tester,
      moamalatReceiptUrl(amount: 45, terminalId: 'SOMEONE-ELSE'),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('payment_scan_receipt_error')),
      findsOneWidget,
    );
    expect(find.textContaining('تمت المطابقة'), findsNothing);
    final confirm = tester.widget<FilledButton>(
      find.byKey(const ValueKey('payment_confirm_button')),
    );
    expect(confirm.onPressed, isNull, reason: 'nothing was matched');
  });

  testWidgets('a receipt scanned before the card payment exists waits for it', (
    tester,
  ) async {
    await _pumpPaymentSheet(tester, total: 45, requireCardReceipt: true);

    // The sheet opens on cash; the cashier scans the slip first.
    _scanIntoSheet(tester, moamalatReceiptUrl(amount: 45));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('payment_scan_pending_receipt')),
      findsOneWidget,
    );
    expect(find.textContaining('تمت المطابقة'), findsNothing);

    // Choosing card is the step it was waiting for — no second scan.
    await tester.tap(find.byKey(const ValueKey('payment_method_card')));
    await tester.pumpAndSettle();

    expect(find.textContaining('تمت المطابقة'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('payment_scan_pending_receipt')),
      findsNothing,
    );
  });

  testWidgets('one terminal slip cannot pay for two card lines', (
    tester,
  ) async {
    await _pumpPaymentSheet(
      tester,
      total: 90,
      width: 1366,
      height: 900,
      requireCardReceipt: true,
      enableCash: false,
      enableTransfer: false,
    );

    await _tapKey(tester, 'payment_tender_amount_0');
    await tester.enterText(
      find.byKey(const ValueKey('payment_tender_amount_0')),
      '45',
    );
    await tester.pump();
    await _tapKey(tester, 'payment_add_tender');

    final url = moamalatReceiptUrl(amount: 45);
    _scanIntoSheet(tester, url);
    await tester.pump();
    expect(find.textContaining('تمت المطابقة'), findsOneWidget);

    // An impatient second trigger on the same slip must not prove the second
    // payment as well.
    _scanIntoSheet(tester, url);
    await tester.pump();

    expect(find.textContaining('تمت المطابقة'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('payment_scan_pending_receipt')),
      findsNothing,
    );
  });

  testWidgets('a receipt an edited amount let go of comes back when the '
      'amount does', (tester) async {
    await _pumpPaymentSheet(
      tester,
      total: 450,
      requireCardReceipt: true,
      enableCash: false,
      enableTransfer: false,
    );

    await tester.enterText(
      find.byKey(const ValueKey('payment_tender_amount_0')),
      '45',
    );
    await tester.pump();

    _scanIntoSheet(tester, moamalatReceiptUrl(amount: 45));
    await tester.pump();
    expect(find.textContaining('تمت المطابقة'), findsOneWidget);

    // The cashier was mid-way through typing 450: the match no longer fits,
    // but the slip is still good and must not be thrown away.
    await tester.enterText(
      find.byKey(const ValueKey('payment_tender_amount_0')),
      '450',
    );
    await tester.pump();
    expect(find.textContaining('تمت المطابقة'), findsNothing);
    expect(
      find.byKey(const ValueKey('payment_scan_pending_receipt')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('payment_tender_amount_0')),
      '45',
    );
    await tester.pump();
    expect(find.textContaining('تمت المطابقة'), findsOneWidget);
  });

  testWidgets('a paired phone matches a receipt the same way the counter '
      'scanner does', (tester) async {
    final bridge = FakeCompanionBridge();
    addTearDown(bridge.dispose);

    await _pumpPaymentSheet(
      tester,
      total: 45,
      requireCardReceipt: true,
      companionBridge: bridge,
    );

    await tester.tap(find.byKey(const ValueKey('payment_method_card')));
    await tester.pumpAndSettle();

    bridge.emitScan(moamalatReceiptUrl(amount: 45));
    await tester.pumpAndSettle();

    expect(find.textContaining('تمت المطابقة'), findsOneWidget);
  });

  testWidgets("a scanner's key burst neither picks a payment method nor "
      'confirms the sale', (tester) async {
    PaymentSheetResult? submitted;
    var now = DateTime(2026, 9, 11, 12);
    await _pumpPaymentSheet(
      tester,
      total: 45,
      clock: () => now,
      onSubmit: (result) => submitted = result,
    );

    // A wedge types a receipt link — digits and all — and ends with Enter.
    // Every one of those digits is also a method hotkey, and that Enter is
    // also the confirm key.
    for (final key in [
      LogicalKeyboardKey.digit9,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.enter,
    ]) {
      now = now.add(const Duration(milliseconds: 10));
      await tester.sendKeyEvent(key);
    }
    await tester.pump();

    expect(
      _tenderMethod(tester, 0),
      PaymentMethod.cash,
      reason: 'the scan must not pick a payment method',
    );
    expect(submitted, isNull, reason: 'the scan must not confirm the sale');

    // The cashier reaching for the method key, at human pace, still works.
    now = now.add(const Duration(seconds: 1));
    await _pressMethodHotkey(tester, LogicalKeyboardKey.digit2);
    expect(_tenderMethod(tester, 0), PaymentMethod.card);

    now = now.add(const Duration(seconds: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(submitted?.payments.single.amount, 45);
  });

  testWidgets('typing a split tender amount does not pick a payment method', (
    tester,
  ) async {
    // The bug a cashier hits on the first split they ever take: the sheet's
    // method hotkeys used to be bare 1/2/3, and a `CallbackShortcuts` ancestor
    // sees a digit the focused text field did not claim. So typing "12" into
    // the first tender selected cash and then card, and the number never
    // arrived. Unreachable on a sale paid one way — the amount is prefilled —
    // and unavoidable on a split.
    PaymentSheetResult? submitted;
    await _pumpPaymentSheet(
      tester,
      total: 30,
      onSubmit: (result) => submitted = result,
    );

    final amountField = find.byKey(const ValueKey('payment_tender_amount_0'));
    // `showKeyboard`, not `tap`: in the compact layout the pinned footer sits
    // over the field's centre, so a tap lands on the confirm button.
    await tester.showKeyboard(amountField);
    await tester.pump();
    // Through the keyboard, not through the controller: `enterText` sets the
    // value directly and never exercises the shortcut at all — which is why
    // the lesson runner did not catch this and a cashier did.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();

    expect(
      _tenderMethod(tester, 0),
      PaymentMethod.cash,
      reason: 'digits typed into an amount must not change the method',
    );

    expect(submitted, isNull, reason: 'typing must not confirm the sale');

    // And the modifier form still selects a method, from the same focus.
    await _pressMethodHotkey(tester, LogicalKeyboardKey.digit2);
    expect(_tenderMethod(tester, 0), PaymentMethod.card);
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
  DateTime? proposedDueDate,
  double height = 844,
  bool requireCardReceipt = false,
  List<String> trustedCardTerminalIds = const [],
  CompanionBridge? companionBridge,
  DateTime Function()? clock,
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
        child: CompanionScope(
          bridge: companionBridge,
          repository: null,
          child: Scaffold(
            body: SizedBox.expand(
              child: PaymentSheet(
                total: total,
                enableCashPayments: enableCash,
                enableCardPayments: enableCard,
                enableTransferPayments: enableTransfer,
                requireCardReceipt: requireCardReceipt,
                trustedCardTerminalIds: trustedCardTerminalIds,
                clock: clock ?? DateTime.now,
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
                proposedDueDate: proposedDueDate,
                onSubmit: onSubmit ?? (_) {},
                onCancel: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Hands the sheet a scan the way the counter scanner does: through the very
/// [BarcodeScanListener] the sheet wired up, so the wiring is under test and
/// not just the handler behind it.
void _scanIntoSheet(WidgetTester tester, String value) {
  tester
      .widget<BarcodeScanListener>(find.byType(BarcodeScanListener))
      .onBarcodeScanned(value);
}

PaymentMethod _tenderMethod(WidgetTester tester, int index) {
  return tester
      .widget<DropdownButtonFormField<PaymentMethod>>(
        find.byKey(ValueKey('payment_tender_method_$index')),
      )
      .initialValue!;
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

/// Ctrl+digit — the payment-method hotkey.
///
/// It is modifier-prefixed because a bare digit reached the sheet's shortcuts
/// even while a tender amount field had focus, so typing an amount picked a
/// payment method instead of entering the number.
Future<void> _pressMethodHotkey(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}
