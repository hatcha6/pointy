import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() {
  testWidgets('falls back to the plain message when nothing is filtered', (
    tester,
  ) async {
    await _pumpEmptyState(tester, query: const ProductQuery());

    expect(find.text('لا توجد منتجات'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('names the search term and offers a clear action', (
    tester,
  ) async {
    var cleared = 0;
    await _pumpEmptyState(
      tester,
      query: const ProductQuery(search: 'شيبس'),
      onClear: () => cleared++,
    );

    expect(find.textContaining('شيبس'), findsOneWidget);
    expect(find.text('لا توجد منتجات'), findsNothing);

    await tester.tap(find.text('مسح البحث والفلاتر'));
    expect(cleared, 1);
  });

  testWidgets('explains a category filter with no search term', (tester) async {
    await _pumpEmptyState(
      tester,
      query: const ProductQuery(
        categories: [ProductCategory(id: 1, name: 'مشروبات')],
      ),
    );

    expect(find.text('لا توجد منتجات مطابقة للفلاتر المحددة'), findsOneWidget);
    expect(find.text('مسح البحث والفلاتر'), findsOneWidget);
  });

  for (final entry in <String, ProductQuery>{
    'availability': ProductQuery(
      availability: ProductAvailabilityFilter.inactive,
    ),
    'supplier': ProductQuery(supplierId: 7, supplierName: 'مورد'),
    'archived': ProductQuery(archived: ProductArchivedFilter.onlyArchived),
  }.entries) {
    testWidgets('offers a way out of a ${entry.key} filter', (tester) async {
      await _pumpEmptyState(
        tester,
        query: entry.value,
        emptyAction: const Text('أضف منتجًا'),
      );

      expect(
        find.text('لا توجد منتجات مطابقة للفلاتر المحددة'),
        findsOneWidget,
      );
      expect(find.text('مسح البحث والفلاتر'), findsOneWidget);
      // The "create one" invitation would be wrong advice here: the product may
      // well exist, just outside the filter.
      expect(find.text('أضف منتجًا'), findsNothing);
    });
  }

  testWidgets('shows the create action only on a genuinely empty catalog', (
    tester,
  ) async {
    await _pumpEmptyState(
      tester,
      query: const ProductQuery(),
      emptyAction: const Text('أضف منتجًا'),
    );

    expect(find.text('لا توجد منتجات'), findsOneWidget);
    expect(find.text('أضف منتجًا'), findsOneWidget);
  });

  test('clearing keeps app-set narrowing and the chosen ordering', () {
    const query = ProductQuery(
      search: 'شيبس',
      categories: [ProductCategory(id: 1, name: 'مشروبات')],
      availability: ProductAvailabilityFilter.inactive,
      archived: ProductArchivedFilter.onlyArchived,
      supplierId: 7,
      supplierName: 'مورد',
      stock: ProductStockFilter.inStockOnly,
      preferredSupplierId: 3,
      ordering: ProductOrdering.priceDesc,
    );

    final cleared = CatalogEmptyState.cleared(query);

    expect(CatalogEmptyState.isFiltered(query), isTrue);
    expect(CatalogEmptyState.isFiltered(cleared), isFalse);
    expect(cleared.supplierId, isNull);
    expect(cleared.stock, ProductStockFilter.inStockOnly);
    expect(cleared.preferredSupplierId, 3);
    expect(cleared.ordering, ProductOrdering.priceDesc);
  });
}

Future<void> _pumpEmptyState(
  WidgetTester tester, {
  required ProductQuery query,
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
          child: CatalogEmptyState(
            query: query,
            emptyMessage: 'لا توجد منتجات',
            onClear: onClear ?? () {},
            emptyAction: emptyAction,
          ),
        ),
      ),
    ),
  );
}
