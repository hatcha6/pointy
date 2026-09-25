import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/features/register_sessions/views/sale_order_details_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// A provider top-up on the shift summary is not an order row: all it knows is
/// the id of the sale it was rung up on. So the sheet it opens has no summary
/// to fall back on, and a failed fetch must say so rather than draw an empty
/// invoice with a zero total.
void main() {
  testWidgets('the sale behind an id is fetched and shown whole', (
    tester,
  ) async {
    final requested = <int>[];
    await _pumpHost(tester, (id) async {
      requested.add(id);
      return SaleOrder.fromJson(_order);
    });

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(requested, [41]);
    expect(find.text('شحن اشتراك HD Box'), findsOneWidget);
  });

  testWidgets('a failed fetch says so and can be retried', (tester) async {
    var calls = 0;
    await _pumpHost(tester, (id) async {
      calls += 1;
      return calls == 1 ? null : SaleOrder.fromJson(_order);
    });

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('تعذر تحميل تفاصيل الفاتورة.'), findsOneWidget);
    expect(find.text('شحن اشتراك HD Box'), findsNothing);

    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('شحن اشتراك HD Box'), findsOneWidget);
  });
}

const _order = <String, Object?>{
  'id': 41,
  'receipt_number': 'R-41',
  'status': 'paid',
  'sale_type': 'standard',
  'payment_status': 'paid',
  'line_count': 1,
  'payments': <Object?>[],
  'subtotal': '30.00',
  'discount_total': '0.00',
  'total': '30.00',
  'created_at': '2026-09-15T09:00:00Z',
  'lines': [
    {
      'id': 410,
      'product_name': 'شحن اشتراك HD Box',
      'quantity': '1',
      'unit_price': '30.00',
      'line_total': '30.00',
    },
  ],
};

Future<void> _pumpHost(
  WidgetTester tester,
  SaleOrderDetailLoader loadDetail,
) async {
  await tester.binding.setSurfaceSize(const Size(900, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSaleOrderDetailsSheetForId(
              context,
              41,
              loadDetail: loadDetail,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
