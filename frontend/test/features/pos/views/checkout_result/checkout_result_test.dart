import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/services/order_document_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/checkout_result/checkout_failure_view.dart';
import 'package:pointy_frontend/src/features/pos/views/checkout_result/checkout_progress_view.dart';
import 'package:pointy_frontend/src/features/pos/views/checkout_result/checkout_receipt_actions.dart';
import 'package:pointy_frontend/src/features/pos/views/checkout_result/checkout_success_view.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';

import '../../../../support/services_testing.dart';
import '../../../../support/test_fonts.dart';

/// The dialog a sale ends in: its progress, its result, its refusal.
void main() {
  setUpAll(loadAppFonts);

  Finder key(String name) => find.byKey(ValueKey(name));

  const order = SaleOrder(
    id: 42,
    status: 'paid',
    receiptNumber: 'R-100',
    lines: [],
    payments: [],
    subtotal: 45,
    total: 45,
  );

  IntegrationChargeResult card({String outcome = 'charged'}) =>
      IntegrationChargeResult.fromJson({
        'fulfillment': 1,
        'order_line': 7,
        'provider': 'qareeb',
        'kind': 'voucher',
        'option_label': 'ليبيانا 20',
        'outcome': outcome,
        'status': outcome == 'charged' ? 'confirmed' : 'pending',
        'receipt': {if (outcome == 'charged') 'code': '1234-5678-9012'},
        'needs_attention': outcome == 'unknown',
      });

  /// Opens [builder] the way the till opens the sale's result.
  Future<void> open(
    WidgetTester tester,
    WidgetBuilder builder, {
    bool settle = true,
  }) async {
    useWindow(tester, const Size(1366, 900));
    await tester.pumpWidget(
      servicesApp(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open'),
              onPressed: () => showPointyResultDialog<void>(
                context: context,
                builder: builder,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(key('open'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // A spinner never settles.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  CheckoutSuccessView success({
    InvoicePrintStatus printStatus = InvoicePrintStatus.printed,
    List<IntegrationChargeResult> recharges = const [],
    double changeDue = 0,
    SaleOrder sale = order,
    bool onlineInvoicesEnabled = false,
    VoidCallback? onOpenSettings,
    CheckoutReceiptHandlers? handlers,
  }) => CheckoutSuccessView(
    order: sale,
    saleType: SaleType.standard,
    printStatus: printStatus,
    recharges: recharges,
    changeDue: changeDue,
    onlineInvoicesEnabled: onlineInvoicesEnabled,
    onOpenSettings: onOpenSettings,
    onDone: () {},
    handlers:
        handlers ??
        CheckoutReceiptHandlers(
          print: () async => InvoicePrintStatus.printed,
          share: () async => OrderDocumentActionStatus.completed,
        ),
  );

  group('a recorded sale', () {
    testServices('puts the change to count out in front', (tester) async {
      await open(tester, (_) => success(changeDue: 5));

      expect(find.text('تم البيع'), findsOneWidget);
      expect(key('checkout_result_figure'), findsOneWidget);
      expect(find.text('الباقي للعميل'), findsOneWidget);
      expect(find.textContaining('5.00'), findsWidgets);
    });

    testServices('says when the receipt did not print, and reprints it', (
      tester,
    ) async {
      var prints = 0;
      await open(
        tester,
        (_) => success(
          printStatus: InvoicePrintStatus.failed,
          handlers: CheckoutReceiptHandlers(
            print: () async {
              prints += 1;
              return InvoicePrintStatus.printed;
            },
          ),
        ),
      );

      expect(key('checkout_print_status_failed'), findsOneWidget);
      await tester.tap(key('checkout_action_print'));
      await tester.pumpAndSettle();

      expect(prints, 1);
      expect(key('checkout_print_status_printed'), findsOneWidget);
    });

    testServices('names the missing printer and where it is set', (
      tester,
    ) async {
      await open(
        tester,
        (_) => success(printStatus: InvoicePrintStatus.noPrinter),
      );

      expect(find.text('عيّنها من إعدادات الجهاز ← الطابعات.'), findsOneWidget);
    });

    testServices('texts the invoice to a number the cashier types', (
      tester,
    ) async {
      String? sentTo;
      await open(
        tester,
        (_) => success(
          handlers: CheckoutReceiptHandlers(
            print: () async => InvoicePrintStatus.printed,
            sendSms: (phone) async {
              sentTo = phone;
              return null;
            },
          ),
        ),
      );

      await tester.tap(key('checkout_action_sms'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), ' 0923456789 ');
      await tester.tap(find.text('إرسال'));
      await tester.pumpAndSettle();

      expect(sentTo, '0923456789');
      expect(find.text('أُرسلت الفاتورة برسالة نصية'), findsOneWidget);
    });

    testServices('says why a text was refused, in Arabic', (tester) async {
      await open(
        tester,
        (_) => success(
          handlers: CheckoutReceiptHandlers(
            print: () async => InvoicePrintStatus.printed,
            sendSms: (_) async => (code: 'invalid_phone', detail: ''),
          ),
        ),
      );

      await tester.tap(key('checkout_action_sms'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '123');
      await tester.tap(find.text('إرسال'));
      await tester.pumpAndSettle();

      expect(key('checkout_action_feedback'), findsOneWidget);
      expect(find.text('أُرسلت الفاتورة برسالة نصية'), findsNothing);
    });

    testServices('offers no SMS to someone who may not send one', (
      tester,
    ) async {
      await open(tester, (_) => success());

      expect(key('checkout_action_sms'), findsNothing);
      expect(key('checkout_action_share'), findsOneWidget);
    });
  });

  group('the invoice link', () {
    testServices('is a QR when the shop publishes links', (tester) async {
      await open(
        tester,
        (_) => success(
          onlineInvoicesEnabled: true,
          sale: const SaleOrder(
            id: 42,
            status: 'paid',
            receiptNumber: 'R-100',
            lines: [],
            payments: [],
            subtotal: 45,
            total: 45,
            publicInvoiceUrl: 'https://shop.dftr.ly/i/abc',
          ),
        ),
      );

      expect(key('invoice_link_card'), findsOneWidget);
      expect(find.byType(PointyQrImage), findsOneWidget);
    });

    testServices('points an owner at the setting when it is off', (
      tester,
    ) async {
      var opened = false;
      await open(tester, (_) => success(onOpenSettings: () => opened = true));

      expect(key('invoice_link_off_hint'), findsOneWidget);
      await tester.tap(key('invoice_link_open_settings'));
      expect(opened, isTrue);
    });

    testServices('is not mentioned to a cashier who cannot switch it on', (
      tester,
    ) async {
      await open(tester, (_) => success());

      expect(key('invoice_link_off_hint'), findsNothing);
      expect(key('invoice_link_card'), findsNothing);
    });
  });

  group('a card sold', () {
    testServices('shows its PIN even though the receipt printed', (
      tester,
    ) async {
      await open(tester, (_) => success(recharges: [card()]));

      expect(key('voucher_codes_card'), findsOneWidget);
      expect(find.text('1234-5678-9012'), findsOneWidget);
      // A PIN still to hand over closes on purpose only.
      expect(CheckoutSuccessView.holdsOpen([card()]), isTrue);
      expect(find.text('تم'), findsOneWidget);
    });

    testServices('that nobody knows the fate of is flagged, not cheered', (
      tester,
    ) async {
      await open(tester, (_) => success(recharges: [card(outcome: 'unknown')]));

      expect(find.text('تم تسجيل البيع، وبعض الشحن لم يكتمل'), findsOneWidget);
      expect(key('recharge_outcome_details'), findsOneWidget);
      expect(key('result_mark_attention'), findsOneWidget);
      expect(CheckoutSuccessView.holdsOpen([card(outcome: 'unknown')]), isTrue);
    });
  });

  group('a refused sale', () {
    CheckoutFailureView failure(
      SaleCheckoutOutcome outcome, {
      VoidCallback? onRetry,
      VoidCallback? onEditPayment,
    }) => CheckoutFailureView(
      outcome: outcome,
      showLossAmounts: false,
      onRetry: onRetry ?? () {},
      onEditPayment: onEditPayment ?? () {},
      onReviewCart: () {},
    );

    testServices('over the credit limit sends the cashier back to payment', (
      tester,
    ) async {
      var edited = false;
      await open(
        tester,
        (_) => failure(
          const SaleCheckoutOutcome.creditLimitRejected(
            SaleCheckoutCreditLimitException(
              limit: 500,
              outstanding: 450,
              available: 50,
              newDebt: 100,
              projected: 550,
            ),
          ),
          onEditPayment: () => edited = true,
        ),
      );

      expect(find.text('لم يتم البيع'), findsOneWidget);
      expect(find.text('لم يُسجَّل أي مبلغ، والسلة كما هي.'), findsOneWidget);
      expect(find.text('تجاوز سقف الدين'), findsOneWidget);
      await tester.tap(key('checkout_failure_editPayment'));
      expect(edited, isTrue);
    });

    testServices('names each line that is short of stock', (tester) async {
      await open(
        tester,
        (_) => failure(
          const SaleCheckoutOutcome.stockRejected([
            SaleStockShortage(
              productName: 'قهوة البيت',
              requested: 2,
              available: 1,
            ),
          ]),
        ),
      );

      expect(find.text('قهوة البيت: المطلوب 2، المتاح 1'), findsOneWidget);
      expect(key('checkout_failure_reviewCart'), findsOneWidget);
    });

    testServices('that got no answer says retrying cannot record it twice', (
      tester,
    ) async {
      var retried = false;
      await open(
        tester,
        (_) => failure(
          const SaleCheckoutOutcome.failure(
            unanswered: true,
            reference: 'AB12CD34',
          ),
          onRetry: () => retried = true,
        ),
      );

      expect(find.text('لم يصل ردّ الخادم'), findsOneWidget);
      expect(
        find.text('إعادة المحاولة آمنة: إن كان البيع قد سُجّل فلن يتكرر.'),
        findsOneWidget,
      );
      expect(find.textContaining('AB12CD34'), findsOneWidget);
      await tester.tap(key('checkout_failure_retry'));
      expect(retried, isTrue);
    });

    testServices('keeps the server\'s Arabic reason', (tester) async {
      await open(
        tester,
        (_) => failure(
          const SaleCheckoutOutcome.failure(
            reason: 'هذا الهاتف ليس له رقم تسلسلي بعد.',
          ),
        ),
      );

      expect(find.text('هذا الهاتف ليس له رقم تسلسلي بعد.'), findsOneWidget);
    });
  });

  group('the progress', () {
    testServices('lists what the sale will do, the running step first', (
      tester,
    ) async {
      await open(
        tester,
        (_) => const CheckoutProgressView(
          saleType: SaleType.standard,
          total: 45,
          progress: PosCheckoutProgress(
            step: PosCheckoutStep.record,
            prints: true,
            chargeLabels: ['ليبيانا 20'],
          ),
        ),
        settle: false,
      );

      expect(find.text('جارٍ إتمام البيع…'), findsOneWidget);
      expect(find.text('تسجيل الفاتورة'), findsOneWidget);
      expect(find.text('التنفيذ لدى المزوّد'), findsOneWidget);
      expect(find.text('طباعة الإيصال'), findsOneWidget);
      expect(key('result_mark_working'), findsOneWidget);
    });
  });

  for (final (name, size, scale) in const [
    ('a phone', Size(390, 844), 1.0),
    ('a small phone with text a third bigger', Size(360, 640), 1.3),
  ]) {
    testServices('$name draws a full result without overflow', (tester) async {
      useWindow(tester, size);
      await tester.pumpWidget(
        servicesApp(
          Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const ValueKey('open'),
                onPressed: () => showPointyResultDialog<void>(
                  context: context,
                  builder: (_) => success(
                    changeDue: 12.5,
                    recharges: [card()],
                    onOpenSettings: () {},
                    printStatus: InvoicePrintStatus.noPrinter,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
          textScale: scale,
        ),
      );
      await tester.tap(key('open'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(key('checkout_new_sale'), findsOneWidget);
    });
  }

  testServices('Escape is the only key the result listens for', (tester) async {
    // Typed digits must not reach anything: the till's scan listener owns
    // them, and a stray Enter is the focused button's.
    await open(tester, (_) => success());
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await tester.pump();
    expect(key('checkout_success'), findsOneWidget);
  });
}
