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

  // The search-mode picker is small, and a product that is only missing
  // because the search was narrowed to the other half is the likeliest
  // reason for a blank list once it is on.
  for (final entry in <ProductSearchMode, String>{
    ProductSearchMode.code:
        'البحث الآن في الباركود ورمز المنتج فقط. اختر «الكل» من قائمة طريقة البحث ليشمل الأسماء.',
    ProductSearchMode.name:
        'البحث الآن في أسماء المنتجات فقط. اختر «الكل» من قائمة طريقة البحث ليشمل الرموز والباركود.',
  }.entries) {
    testWidgets('says a search narrowed to ${entry.key.name} was narrowed', (
      tester,
    ) async {
      await _pumpEmptyState(
        tester,
        query: ProductQuery(search: 'شيبس', searchMode: entry.key),
      );

      expect(find.textContaining('شيبس'), findsOneWidget);
      expect(find.text(entry.value), findsOneWidget);
    });
  }

  testWidgets('a mode with nothing typed is no reason to mention it', (
    tester,
  ) async {
    await _pumpEmptyState(
      tester,
      query: const ProductQuery(
        categories: [ProductCategory(id: 1, name: 'مشروبات')],
        searchMode: ProductSearchMode.name,
      ),
    );

    expect(
      find.text('تحقق من الكتابة أو امسح البحث والفلاتر لعرض كل المنتجات.'),
      findsOneWidget,
    );
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
      searchMode: ProductSearchMode.name,
    );

    final cleared = CatalogEmptyState.cleared(query);

    expect(CatalogEmptyState.isFiltered(query), isTrue);
    expect(CatalogEmptyState.isFiltered(cleared), isFalse);
    expect(cleared.supplierId, isNull);
    expect(cleared.stock, ProductStockFilter.inStockOnly);
    expect(cleared.preferredSupplierId, 3);
    expect(cleared.ordering, ProductOrdering.priceDesc);
    // How the cashier searches is a choice, not a filter: clearing the search
    // leaves the picker where they put it.
    expect(cleared.searchMode, ProductSearchMode.name);
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
