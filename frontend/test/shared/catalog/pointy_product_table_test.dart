import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/product_tile.dart';

void main() {
  testWidgets('renders desktop table columns and opens a product', (
    tester,
  ) async {
    Product? opened;

    await _pumpTable(
      tester,
      width: 1366,
      products: [_product(quantity: 45, barcode: '6281100001234')],
      onOpenProduct: (product) => opened = product,
    );

    expect(find.text('المنتج'), findsOneWidget);
    expect(find.text('المخزون'), findsOneWidget);
    expect(find.text('السعر'), findsOneWidget);
    expect(find.text('الباركود'), findsOneWidget);
    expect(find.text('تعديل'), findsOneWidget);
    expect(find.text('قهوة عربية'), findsOneWidget);
    expect(find.text('متوفر'), findsOneWidget);
    expect(find.text('6281100001234'), findsOneWidget);

    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();

    expect(opened?.id, 42);
  });

  testWidgets('renders compact rows with low stock and missing barcode', (
    tester,
  ) async {
    Product? opened;

    await _pumpTable(
      tester,
      width: 390,
      products: [_product(quantity: 3, barcode: '')],
      onOpenProduct: (product) => opened = product,
    );

    expect(find.text('المنتج'), findsNothing);
    expect(find.text('قهوة عربية'), findsOneWidget);
    expect(find.text('منخفض'), findsOneWidget);
    expect(find.text('لا يوجد باركود'), findsOneWidget);

    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();

    expect(opened?.id, 42);
  });
}

Future<void> _pumpTable(
  WidgetTester tester, {
  required double width,
  required List<Product> products,
  required ValueChanged<Product> onOpenProduct,
}) async {
  tester.view.physicalSize = Size(width, 760);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: SizedBox.expand(
            child: PointyProductTable(
              products: products,
              onOpenProduct: onOpenProduct,
              onLoadMore: () async {},
              hasMore: false,
              isLoadingInitial: false,
              isLoadingMore: false,
              emptyBuilder: (_) => const Text('فارغ'),
            ),
          ),
        ),
      ),
    ),
  );
}

Product _product({required int quantity, required String barcode}) {
  return Product(
    id: 42,
    name: 'قهوة عربية',
    quantityOnHand: quantity,
    categories: const [ProductCategory(id: 7, name: 'مشروبات')],
    defaultVariant: ProductVariant(
      id: 42,
      productId: 42,
      sku: 'COF-100',
      barcode: barcode,
      unitPrice: 5.50,
      quantityOnHand: quantity,
    ),
  );
}
