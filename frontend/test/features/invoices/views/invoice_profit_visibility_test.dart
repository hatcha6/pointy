import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/features/invoices/views/invoice_list_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/order/sale_order_details_content.dart';

/// Profit on an invoice is the owner's number, and the server decides who
/// reads it: it leaves `total_profit`, the lines' cost and profit, and a
/// top-up's provider cost out of the payload for everyone outside the
/// reporting roles. These screens draw a figure only when it arrives — the
/// frozen Windows 7/8 till build too — so the payload a cashier gets is what
/// keeps the profit off their screen.
void main() {
  Map<String, Object?> invoice({required bool withMargins}) => {
    'id': 21,
    'receipt_number': 'R20260926000021',
    'status': 'paid',
    'sale_type': 'standard',
    'subtotal': '38.00',
    'total': '38.00',
    'payment_status': 'paid',
    'payments': const <Object?>[],
    'line_count': 2,
    if (withMargins) 'total_cost': '28.00',
    if (withMargins) 'total_profit': '10.00',
    'lines': [
      {
        'id': 1,
        'product': 4,
        'variant': 4,
        'product_name': 'شاي',
        'quantity': 2,
        'returned_quantity': 0,
        'returnable_quantity': 2,
        'unit_price': '4.00',
        'line_total': '8.00',
        if (withMargins) 'unit_cost': '1.50',
        if (withMargins) 'line_cost': '3.00',
        if (withMargins) 'line_profit': '5.00',
      },
      {
        'id': 2,
        'product': 90,
        'variant': 90,
        'product_name': 'شحن اشتراك',
        'quantity': 1,
        'returned_quantity': 0,
        'returnable_quantity': 0,
        'unit_price': '30.00',
        'line_total': '30.00',
        if (withMargins) 'line_profit': '5.00',
        'integration': {
          'provider': 'hdbox',
          'subscriber_ref': '7001',
          'option_label': '1 month',
          'status': 'confirmed',
          if (withMargins) 'cost': '25.00',
        },
      },
    ],
  };

  testWidgets('a cashier\'s invoice row and document carry no profit', (
    tester,
  ) async {
    final order = SaleOrder.fromJson(invoice(withMargins: false));
    expect(order.profit, isNull);

    await tester.pumpWidget(_app(InvoiceTile(invoice: order)));
    expect(find.textContaining('الربح'), findsNothing);

    await tester.pumpWidget(_app(SaleOrderDetailsContent(order: order)));
    await tester.pumpAndSettle();
    expect(find.textContaining('الربح'), findsNothing);
    expect(find.textContaining('التكلفة على المتجر'), findsNothing);
    // The top-up itself is still described — only its cost is withheld.
    expect(find.textContaining('7001'), findsOneWidget);
  });

  testWidgets('the owner\'s shows it on the row, the lines and the top-up', (
    tester,
  ) async {
    final order = SaleOrder.fromJson(invoice(withMargins: true));

    await tester.pumpWidget(_app(InvoiceTile(invoice: order)));
    expect(find.textContaining('الربح'), findsOneWidget);

    await tester.pumpWidget(_app(SaleOrderDetailsContent(order: order)));
    await tester.pumpAndSettle();
    // The document's figure, and one under each of its two lines.
    expect(find.textContaining('الربح'), findsNWidgets(3));
    expect(find.textContaining('التكلفة على المتجر'), findsOneWidget);
  });
}

Widget _app(Widget child) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: PointyTheme.light(),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}
