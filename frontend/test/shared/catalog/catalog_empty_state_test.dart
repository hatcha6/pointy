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

    await tester.tap(find.text('مسح البحث والتصنيف'));
    expect(cleared, 1);
  });

  testWidgets('explains a category filter with no search term', (tester) async {
    await _pumpEmptyState(
      tester,
      query: const ProductQuery(
        categories: [ProductCategory(id: 1, name: 'مشروبات')],
      ),
    );

    expect(find.text('لا توجد منتجات ضمن هذا التصنيف'), findsOneWidget);
    expect(find.text('مسح البحث والتصنيف'), findsOneWidget);
  });
}

Future<void> _pumpEmptyState(
  WidgetTester tester, {
  required ProductQuery query,
  VoidCallback? onClear,
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
          ),
        ),
      ),
    ),
  );
}
