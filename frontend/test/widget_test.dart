import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/app.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_details_screen.dart';
import 'package:pointy_frontend/src/shared/infinite_scroll_grid.dart';

void main() {
  testWidgets('POS shell renders and accepts cart input', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const PointyApp());
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('نقطة البيع'), findsOneWidget);
    expect(find.text('البيع الحالي'), findsOneWidget);

    await tester.tap(find.text('قهوة البيت'));
    await tester.pump();

    expect(find.text('ادفع د.ل 3.50'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets('catalog screen exposes the product creation form', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const PointyApp());
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المنتجات').last);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('إدارة المنتجات'), findsOneWidget);
    expect(find.text('إضافة منتج'), findsOneWidget);
    expect(find.text('منتج جديد'), findsNothing);

    await tester.tap(find.text('إضافة منتج'));
    await tester.pumpAndSettle();

    expect(find.text('منتج جديد'), findsOneWidget);
    expect(find.text('اسم المنتج'), findsOneWidget);
    expect(find.text('رمز المنتج'), findsOneWidget);
    expect(find.text('إنشاء المنتج'), findsOneWidget);
  });

  testWidgets('POS screen exposes reusable search and ordering controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const PointyApp());
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('ابحث باسم المنتج أو الرمز'), findsOneWidget);
    expect(find.byTooltip('الفلاتر والترتيب'), findsOneWidget);

    await tester.tap(find.byTooltip('الفلاتر والترتيب'));
    await tester.pumpAndSettle();

    expect(find.text('الفلاتر والترتيب'), findsOneWidget);
    expect(find.text('ترتيب النتائج'), findsOneWidget);
    expect(find.text('حالة المنتج'), findsNothing);
  });

  testWidgets(
    'catalog screen exposes reusable search, filtering, and ordering controls',
    (WidgetTester tester) async {
      await tester.pumpWidget(const PointyApp());
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('المنتجات').last);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.text('ابحث باسم المنتج أو الرمز'), findsOneWidget);
      expect(find.byTooltip('الفلاتر والترتيب'), findsOneWidget);

      await tester.tap(find.byTooltip('الفلاتر والترتيب'));
      await tester.pumpAndSettle();

      expect(find.text('الفلاتر والترتيب'), findsOneWidget);
      expect(find.text('حالة المنتج'), findsOneWidget);
      expect(find.text('ترتيب النتائج'), findsOneWidget);
      expect(find.text('السعر: من الأعلى إلى الأقل'), findsOneWidget);
    },
  );

  testWidgets('navigation drawer exposes primary destinations', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const PointyApp());
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('القائمة'), findsOneWidget);
    expect(find.text('شاشة البيع'), findsOneWidget);
    expect(find.text('المنتجات'), findsWidgets);
  });

  testWidgets('product details screen presents product information', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: ProductDetailsScreen(
          product: Product(
            id: 42,
            sku: 'COF-100',
            name: 'قهوة عربية',
            unitPrice: 5.50,
            barcode: '123456',
            description: 'حبوب مطحونة بعناية',
          ),
        ),
      ),
    );

    expect(find.text('تفاصيل المنتج'), findsOneWidget);
    expect(find.text('قهوة عربية'), findsOneWidget);
    expect(find.text('د.ل 5.50'), findsOneWidget);
    expect(find.text('123456'), findsOneWidget);
    expect(find.text('حبوب مطحونة بعناية'), findsOneWidget);
  });

  testWidgets('infinite grid requests more data when content underfills', (
    WidgetTester tester,
  ) async {
    var loadMoreCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 320,
          width: 320,
          child: InfiniteScrollGrid<int>(
            items: const [1],
            hasMore: true,
            isLoadingInitial: false,
            isLoadingMore: false,
            onLoadMore: () async {
              loadMoreCalls += 1;
            },
            emptyBuilder: (_) => const Text('empty'),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisExtent: 120,
            ),
            itemBuilder: (_, item) => Text('$item'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(loadMoreCalls, 1);
  });
}
