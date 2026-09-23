import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';
import 'package:pointy_frontend/src/shared/product_tile.dart';

void main() {
  // Barcode goes first, then stock; the product and its price never do.
  for (final (width, showsStock, showsBarcode) in [
    (400.0, false, false),
    (600.0, true, false),
    (900.0, true, true),
  ]) {
    testWidgets('at width $width the table keeps the columns that fit', (
      tester,
    ) async {
      await _pumpTable(tester, width: width, products: [_coffee, _repair]);

      expect(find.text('المنتج'), findsOneWidget);
      expect(find.text('السعر'), findsOneWidget);
      expect(find.text('المخزون'), showsStock ? findsOneWidget : findsNothing);
      expect(
        find.text('الباركود'),
        showsBarcode ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('6281100001234'),
        showsBarcode ? findsOneWidget : findsNothing,
      );
      expect(find.text('قهوة عربية'), findsOneWidget);
      expect(find.text('COF-100'), findsOneWidget);
      expect(find.text('5.50 د.ل'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('stock is a count, and a dash for what keeps no stock', (
    tester,
  ) async {
    // Stock shown, barcode not — so the only dash is the stock column's.
    await _pumpTable(tester, width: 600, products: [_coffee, _repair]);

    expect(find.text(ltrIsolated('3')), findsOneWidget);
    // The low count names its status on hover.
    expect(find.byTooltip('منخفض'), findsOneWidget);
    // A repair is a service: zero on hand would read as "sold out".
    expect(find.text('—'), findsOneWidget);
    expect(find.text(ltrIsolated('0')), findsNothing);
  });

  testWidgets('a product already in the sale shows its count, not the cue', (
    tester,
  ) async {
    await _pumpTable(
      tester,
      width: 900,
      products: [_coffee, _repair],
      cartQuantities: {_coffee.id: 2},
    );

    final coffee = find.byKey(ValueKey(_coffee.id));
    expect(
      find.descendant(
        of: coffee,
        matching: find.byType(PointyCartQuantityBadge),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: coffee, matching: find.text('2')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: coffee, matching: find.byType(PointyAddToOrderCue)),
      findsNothing,
    );
    final repair = find.byKey(ValueKey(_repair.id));
    expect(
      find.descendant(of: repair, matching: find.byType(PointyAddToOrderCue)),
      findsOneWidget,
    );
  });

  testWidgets('tapping a row picks its product; a disabled one does not', (
    tester,
  ) async {
    final picked = <int>[];
    await _pumpTable(
      tester,
      width: 600,
      products: [_coffee, _repair],
      onTap: (product) =>
          product.id == _repair.id ? null : () => picked.add(product.id),
    );

    await tester.tap(find.text('قهوة عربية'));
    await tester.tap(find.text('صيانة جوال'));
    await tester.pump();

    expect(picked, [_coffee.id]);
  });

  testWidgets('the first load shows the header over placeholder rows', (
    tester,
  ) async {
    await _pumpTable(
      tester,
      width: 600,
      products: const [],
      isLoadingInitial: true,
    );

    expect(find.text('المنتج'), findsOneWidget);
    expect(find.byType(PointySkeletonListTile), findsWidgets);
    expect(find.text('فارغ'), findsNothing);
  });

  testWidgets('an empty result is the empty state alone, without a header', (
    tester,
  ) async {
    await _pumpTable(tester, width: 600, products: const []);

    expect(find.text('فارغ'), findsOneWidget);
    expect(find.text('المنتج'), findsNothing);
  });
}

Future<void> _pumpTable(
  WidgetTester tester, {
  required double width,
  required List<Product> products,
  Map<int, double> cartQuantities = const {},
  VoidCallback? Function(Product product)? onTap,
  bool isLoadingInitial = false,
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
      home: Scaffold(
        body: SizedBox.expand(
          child: PointyCatalogTable<Product>(
            items: products,
            onLoadMore: () async {},
            hasMore: false,
            isLoadingInitial: isLoadingInitial,
            isLoadingMore: false,
            emptyBuilder: (_) => const Text('فارغ'),
            itemBuilder: (context, product) => ProductTile.row(
              key: ValueKey(product.id),
              product: product,
              cartQuantity: cartQuantities[product.id] ?? 0,
              onTap: onTap == null ? () {} : onTap(product),
            ),
          ),
        ),
      ),
    ),
  );
}

const _coffee = Product(
  id: 42,
  name: 'قهوة عربية',
  quantityOnHand: 3,
  defaultVariant: ProductVariant(
    id: 42,
    productId: 42,
    sku: 'COF-100',
    barcode: '6281100001234',
    unitPrice: 5.50,
    quantityOnHand: 3,
  ),
);

const _repair = Product(
  id: 43,
  name: 'صيانة جوال',
  quantityOnHand: 0,
  isService: true,
  defaultVariant: ProductVariant(
    id: 43,
    productId: 43,
    sku: 'SRV-1',
    unitPrice: 20,
  ),
);
