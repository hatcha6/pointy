import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/discount_rule.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/features/discounts/views/discount_rule_query_controls.dart';
import 'package:pointy_frontend/src/features/invoices/views/invoice_query_controls.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_order_query_controls.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/query_controls/query_empty_state.dart';

/// The invoice, purchase-order and discount lists all went blank the same way
/// — one flat "there are none" line — whether the shop had no records at all
/// or the user had simply filtered them out. This proves the two now read
/// differently and that the filtered one carries a way back.
void main() {
  testWidgets('an unfiltered list keeps its plain message and create action', (
    tester,
  ) async {
    await _pumpEmptyState(
      tester,
      search: '',
      hasFilters: false,
      emptyAction: const Text('فاتورة جديدة'),
    );

    expect(find.text('لا توجد فواتير بعد.'), findsOneWidget);
    expect(find.text('فاتورة جديدة'), findsOneWidget);
    expect(find.text('مسح البحث والفلاتر'), findsNothing);
  });

  testWidgets('a search that matched nothing quotes the term back', (
    tester,
  ) async {
    var cleared = 0;
    await _pumpEmptyState(
      tester,
      search: '  1042  ',
      hasFilters: false,
      onClear: () => cleared++,
      emptyAction: const Text('فاتورة جديدة'),
    );

    expect(find.textContaining('1042'), findsOneWidget);
    expect(find.text('لا توجد فواتير بعد.'), findsNothing);
    // Offering "create one" here would invite a duplicate of a record that is
    // sitting just outside the filter.
    expect(find.text('فاتورة جديدة'), findsNothing);

    // No filter is narrowing this list, so the escape must not point at the
    // funnel — the contact pickers do not even have one.
    expect(find.text('مسح البحث والفلاتر'), findsNothing);
    await tester.tap(find.text('مسح البحث'));
    expect(cleared, 1);
  });

  testWidgets('a filter with no search term names only the filters', (
    tester,
  ) async {
    await _pumpEmptyState(tester, search: '', hasFilters: true);

    expect(find.text('لا توجد نتائج مطابقة للفلاتر المحددة'), findsOneWidget);
    expect(find.text('امسح الفلاتر لعرض القائمة كاملة.'), findsOneWidget);
    expect(find.text('مسح الفلاتر'), findsOneWidget);

    // Mirror of the search-only case above: the user typed nothing, so telling
    // them to check their spelling and offering to clear a search box — which
    // the payments hub and the contact pickers do not even have — points at a
    // control that will not change anything.
    expect(find.text('مسح البحث والفلاتر'), findsNothing);
    expect(find.text('مسح البحث'), findsNothing);
    expect(
      find.text('تحقق من الكتابة، أو امسح البحث والفلاتر لعرض القائمة كاملة.'),
      findsNothing,
    );
  });

  testWidgets('a search term and a filter together name both', (tester) async {
    await _pumpEmptyState(tester, search: '1042', hasFilters: true);

    expect(find.text('لا توجد نتائج لـ «1042»'), findsOneWidget);
    expect(
      find.text('تحقق من الكتابة، أو امسح البحث والفلاتر لعرض القائمة كاملة.'),
      findsOneWidget,
    );
    expect(find.text('مسح البحث والفلاتر'), findsOneWidget);
    expect(find.text('مسح الفلاتر'), findsNothing);
  });

  group('clearing keeps what the user did not set', () {
    test('invoices keep the caller-set product scope and the ordering', () {
      const query = SaleOrderQuery(
        search: '1042',
        status: SaleOrderStatusFilter.voided,
        customerId: 7,
        customerName: 'زبون',
        productId: 3,
        variantId: 4,
        ordering: SaleOrderOrdering.totalDesc,
      );

      final cleared = InvoiceQueryControls.cleared(query);

      expect(InvoiceQueryControls.narrowingFilterCount(query), 2);
      expect(InvoiceQueryControls.narrowingFilterCount(cleared), 0);
      expect(cleared.search, isEmpty);
      expect(cleared.customerId, isNull);
      expect(cleared.customerName, isNull);
      expect(cleared.productId, 3);
      expect(cleared.variantId, 4);
      expect(cleared.ordering, SaleOrderOrdering.totalDesc);
    });

    test('purchase orders keep the caller-set product scope', () {
      const query = PurchaseOrderQuery(
        search: 'PO-9',
        status: PurchaseOrderStatusFilter.draft,
        supplierId: 5,
        supplierName: 'مورد',
        productId: 3,
        ordering: PurchaseOrderOrdering.totalDesc,
      );

      final cleared = PurchaseOrderQueryControls.cleared(query);

      expect(PurchaseOrderQueryControls.narrowingFilterCount(query), 2);
      expect(PurchaseOrderQueryControls.narrowingFilterCount(cleared), 0);
      expect(cleared.search, isEmpty);
      expect(cleared.supplierId, isNull);
      expect(cleared.supplierName, isNull);
      expect(cleared.productId, 3);
      expect(cleared.ordering, PurchaseOrderOrdering.totalDesc);
    });

    test('discounts drop every filter but keep the ordering', () {
      const query = DiscountRuleQuery(
        search: 'رمضان',
        status: DiscountRuleStatusFilter.inactive,
        channel: DiscountRuleChannelFilter.sales,
        application: DiscountRuleApplicationFilter.automatic,
        ordering: DiscountRuleOrdering.newest,
      );

      final cleared = DiscountRuleQueryControls.cleared(query);

      expect(query.activeFilterCount, 3);
      expect(cleared.activeFilterCount, 0);
      expect(cleared.search, isEmpty);
      expect(cleared.ordering, DiscountRuleOrdering.newest);
    });
  });

  // Sorting reorders a list; it can never empty one. Counting it as a filter
  // would blame the funnel for a shop that simply has no records yet.
  test('a non-default ordering alone is not a narrowing filter', () {
    expect(
      InvoiceQueryControls.narrowingFilterCount(
        const SaleOrderQuery(ordering: SaleOrderOrdering.totalDesc),
      ),
      0,
    );
    expect(
      PurchaseOrderQueryControls.narrowingFilterCount(
        const PurchaseOrderQuery(ordering: PurchaseOrderOrdering.totalDesc),
      ),
      0,
    );
    expect(
      const DiscountRuleQuery(
        ordering: DiscountRuleOrdering.newest,
      ).activeFilterCount,
      0,
    );
  });
}

Future<void> _pumpEmptyState(
  WidgetTester tester, {
  required String search,
  required bool hasFilters,
  VoidCallback? onClear,
  Widget? emptyAction,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Material(
          child: QueryEmptyState(
            icon: Icons.receipt_long_outlined,
            search: search,
            hasFilters: hasFilters,
            emptyTitle: 'لا توجد فواتير بعد.',
            onClear: onClear ?? () {},
            emptyAction: emptyAction,
          ),
        ),
      ),
    ),
  );
}
