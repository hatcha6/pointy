import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/features/pos/views/recharge_outcome_dialog.dart';

import '../../../support/services_testing.dart';
import '../../../support/test_fonts.dart';

/// What the cashier is told when a card or top-up a sale sold was not
/// delivered — and, since the server now gives a refused line back, how much
/// to hand back (Annaseem 2026-10-11: eight refused cards stayed paid sales).
void main() {
  setUpAll(loadAppFonts);

  IntegrationChargeResult refused({
    required String provider,
    String errorCode = 'provider_error',
    String? refundAmount,
  }) => IntegrationChargeResult.fromJson({
    'fulfillment': 1,
    'order_line': 7,
    'provider': provider,
    'kind': 'voucher',
    'option_label': 'ببجي 16200 UC',
    'outcome': 'refused',
    'status': 'pending',
    'error_code': errorCode,
    'refunded': refundAmount != null,
    'refund_amount': refundAmount,
  });

  Future<void> open(
    WidgetTester tester,
    List<IntegrationChargeResult> rows,
  ) async {
    useWindow(tester, const Size(1366, 768));
    await tester.pumpWidget(
      servicesApp(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open'),
              onPressed: () => showRechargeOutcomeDialog(context, rows),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  testServices('a refused card that was given back names the amount', (
    tester,
  ) async {
    await open(tester, [
      refused(provider: 'qareeb', refundAmount: '1919.00'),
      refused(provider: 'qareeb', refundAmount: '1919.00'),
    ]);

    expect(find.text('لم يُنفَّذ الشحن'), findsOneWidget);
    expect(
      find.textContaining('أُلغي من الفاتورة تلقائياً — أعِد 1919.00'),
      findsNWidgets(2),
    );
    expect(
      find.textContaining('المبلغ المُعاد للزبون: 3838.00'),
      findsOneWidget,
    );
  });

  testServices('an older server that refunded nothing says no amount', (
    tester,
  ) async {
    await open(tester, [refused(provider: 'qareeb')]);

    expect(find.textContaining('أُلغي من الفاتورة'), findsNothing);
    expect(
      find.byKey(const ValueKey('recharge_outcome_refund_total')),
      findsNothing,
    );
  });

  testServices('an empty Daftar card balance points at «رصيد الكروت»', (
    tester,
  ) async {
    // The owner read «رصيد الوكالة», topped up Qareeb, and was refused again.
    await open(tester, [
      refused(provider: 'pointy', errorCode: 'insufficient_float'),
    ]);

    expect(
      find.text('رصيد الكروت لا يكفي — حوّل من المحفظة ثم أعد البيع.'),
      findsOneWidget,
    );
    expect(find.textContaining('رصيد الوكالة'), findsNothing);
  });

  testServices('an empty agency float still says the agency', (tester) async {
    await open(tester, [
      refused(provider: 'qareeb', errorCode: 'insufficient_float'),
    ]);

    expect(find.textContaining('رصيد الوكالة لا يكفي'), findsOneWidget);
  });
}
