import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/features/pos/views/cart_line_tile.dart';

import '../../../support/services_testing.dart';
import '../../../support/test_fonts.dart';

/// An airtime or bill line held in an invoice is priced by a quote as old as
/// the invoice has been held: its row says so, so the cashier knows before
/// they ask the customer to pay.
void main() {
  setUpAll(loadAppFonts);

  CartLine service({DateTime? quotedAt, bool testMode = false}) =>
      CartLine.create(
        variant: const ProductVariant(
          id: 9301,
          productId: 0,
          sku: '',
          unitPrice: 96.5,
          productName: 'شحن مباشر',
          isService: true,
        ),
        quantity: 1,
        integration: CartLineIntegration(
          provider: 'pointy',
          subscriberRef: '+22370123456',
          optionCode: 'air:289:5000:XOF',
          optionLabel: 'أورنج مالي · 5,000 فرنك أفريقي',
          quote: 'sealed',
          quotedAt: quotedAt,
          testMode: testMode,
        ),
      );

  Future<void> show(WidgetTester tester, CartLine line) => tester.pumpWidget(
    servicesApp(
      SingleChildScrollView(
        child: CartLineTile(line: line, onAdd: null, onRemove: null),
      ),
    ),
  );

  testWidgets('says how long ago a held service line was priced', (
    tester,
  ) async {
    await show(
      tester,
      service(
        quotedAt: DateTime.now().subtract(const Duration(hours: 3, minutes: 5)),
      ),
    );

    expect(find.text('سُعّرت قبل 3 ساعات'), findsOneWidget);
  });

  testWidgets('says nothing about a line priced a moment ago', (tester) async {
    await show(tester, service(quotedAt: DateTime.now()));

    expect(find.textContaining('سُعّرت'), findsNothing);
  });

  testWidgets('says nothing about a line that never said when', (tester) async {
    await show(tester, service());

    expect(find.textContaining('سُعّرت'), findsNothing);
  });

  testWidgets('says «عملية تجريبية» on a line sold in test mode', (
    tester,
  ) async {
    await show(tester, service(testMode: true));

    expect(
      find.byKey(const ValueKey('service_test_mode_mark')),
      findsOneWidget,
    );
    expect(find.text('عملية تجريبية'), findsOneWidget);
  });

  testWidgets('says it beside how old the price is, not instead', (
    tester,
  ) async {
    await show(
      tester,
      service(
        testMode: true,
        quotedAt: DateTime.now().subtract(const Duration(hours: 3, minutes: 5)),
      ),
    );

    expect(find.text('عملية تجريبية'), findsOneWidget);
    expect(find.text('سُعّرت قبل 3 ساعات'), findsOneWidget);
  });

  testWidgets('says nothing of test mode on a line sold for real', (
    tester,
  ) async {
    await show(tester, service());

    expect(find.byKey(const ValueKey('service_test_mode_mark')), findsNothing);
    expect(find.text('عملية تجريبية'), findsNothing);
  });

  testWidgets('says nothing on an ordinary line', (tester) async {
    await show(
      tester,
      CartLine.create(
        variant: const ProductVariant(
          id: 7,
          productId: 1,
          sku: 'RICE-1',
          unitPrice: 10,
          productName: 'أرز',
        ),
        quantity: 1,
      ),
    );

    expect(find.textContaining('سُعّرت'), findsNothing);
    expect(find.text('RICE-1'), findsOneWidget);
  });
}
