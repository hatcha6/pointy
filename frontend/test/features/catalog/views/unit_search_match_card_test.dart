import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/features/catalog/views/unit_search_match_card.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../unit_search_fixtures.dart';

/// The card above the products when an identifier answers. Its job is the
/// question somebody typed the IMEI for — *did we sell this, and to whom* —
/// and to open the article in one tap.
void main() {
  final opened = <int>[];
  final invoices = <int>[];
  final customers = <int>[];

  setUp(() {
    opened.clear();
    invoices.clear();
    customers.clear();
  });

  Future<void> pump(
    WidgetTester tester,
    StockUnitLookup lookup, {
    String typed = imei,
    bool links = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(480, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: UnitSearchMatchCard(
              lookup: lookup,
              typedCode: typed,
              onOpenUnit: (unit) => opened.add(unit.id),
              onOpenInvoice: links ? invoices.add : null,
              onOpenCustomer: links ? customers.add : null,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'a live handset: what, where, for how much — and Enter opens it',
    (tester) async {
      await pump(tester, lookupOf(unit: liveUnitJson()));

      expect(find.text('جهاز بهذا الرقم'), findsOneWidget);
      expect(find.text('اضغط Enter لفتحه'), findsOneWidget);
      expect(find.text('آيفون 13 برو · 256GB أزرق'), findsOneWidget);
      expect(find.text('في المخزون'), findsOneWidget);
      expect(find.text('المحل الرئيسي'), findsOneWidget);
      expect(find.textContaining('1450.00'), findsOneWidget);
      expect(find.byKey(const ValueKey('unit_sale_band')), findsNothing);

      await tester.tap(find.text('آيفون 13 برو · 256GB أزرق'));
      expect(opened, [41]);
    },
  );

  testWidgets('the second IMEI typed says so', (tester) async {
    await pump(tester, lookupOf(unit: liveUnitJson()), typed: secondImei);
    expect(find.textContaining('مطابق للرقم الثاني'), findsOneWidget);
  });

  testWidgets('a sold handset names its buyer, its invoice and its cover', (
    tester,
  ) async {
    await pump(
      tester,
      lookupOf(
        history: [soldUnitJson()],
        warranty: coveredWarranty(repairs: 2),
      ),
    );

    expect(find.text('بيع إلى أحمد علي'), findsOneWidget);
    expect(find.textContaining('INV-000123'), findsOneWidget);
    expect(find.textContaining('الضمان حتى'), findsOneWidget);
    expect(find.text('أُصلح مرتين'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('unit_search_invoice_link')));
    await tester.tap(find.byKey(const ValueKey('unit_search_customer_link')));
    expect(invoices, [900]);
    expect(customers, [5]);
    expect(opened, isEmpty);
  });

  testWidgets('a reader who may not see the sale is told only when', (
    tester,
  ) async {
    await pump(tester, lookupOf(history: [soldUnitJson(withSale: false)]));

    expect(find.textContaining('بيع في'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('unit_search_invoice_link')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('unit_search_customer_link')),
      findsNothing,
    );
  });

  testWidgets('an expired warranty reads as expired', (tester) async {
    await pump(
      tester,
      lookupOf(
        history: [soldUnitJson(warrantyExpiresOn: DateTime(2025, 1, 1))],
      ),
    );
    expect(find.textContaining('انتهى في'), findsOneWidget);
  });

  testWidgets(
    'a trade-in: the live one leads, earlier sales follow, no Enter',
    (tester) async {
      await pump(
        tester,
        lookupOf(
          unit: liveUnitJson(),
          history: [
            soldUnitJson(id: 40, customerName: 'سالم'),
            soldUnitJson(id: 39, receipt: 'INV-000077'),
          ],
        ),
      );

      expect(find.text('3 سجلات لهذا الرقم'), findsOneWidget);
      expect(find.text('اضغط Enter لفتحه'), findsNothing);
      expect(find.text('سجل سابق لهذا الرقم'), findsOneWidget);
      expect(find.textContaining('سالم'), findsOneWidget);

      await tester.tap(find.textContaining('INV-000077'));
      expect(opened, [39]);
    },
  );

  testWidgets('without links the buyer and invoice are text, not buttons', (
    tester,
  ) async {
    await pump(tester, lookupOf(history: [soldUnitJson()]), links: false);
    await tester.tap(find.byKey(const ValueKey('unit_search_invoice_link')));
    expect(invoices, isEmpty);
  });
}
