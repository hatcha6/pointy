import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/features/pos/views/cart_line_tile.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_sale_session_strip.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/order/order.dart';
import 'package:pointy_frontend/src/shared/product_tile.dart';

void main() {
  test('product card grid keeps catalog card proportions consistent', () {
    final compact = PointyProductCardGrid.delegateFor(width: 390, spacing: 12);
    expect(compact.crossAxisCount, 2);
    expect(compact.mainAxisExtent, PointyProductCardGrid.tileMainExtent);
    expect(compact.crossAxisSpacing, 12);
    expect(compact.mainAxisSpacing, 12);

    final wide = PointyProductCardGrid.delegateFor(width: 1400, spacing: 20);
    expect(wide.crossAxisCount, PointyProductCardGrid.maxColumnCount);
    expect(wide.mainAxisExtent, PointyProductCardGrid.wideTileMainExtent);
  });

  for (final width in [390.0, 768.0, 1366.0]) {
    testWidgets('POS product card stays usable at width $width', (
      tester,
    ) async {
      await _pumpAtWidth(
        tester,
        width: width,
        child: SizedBox(
          width: width < 480 ? 180 : 220,
          height: 236,
          child: ProductTile(product: _longNameProduct, onTap: () {}),
        ),
      );

      expect(find.byType(ProductTile), findsOneWidget);
      expect(find.textContaining('قهوة عربية'), findsOneWidget);
      expect(find.text('12.75 د.ل'), findsOneWidget);
      expect(find.byIcon(Icons.add_shopping_cart_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('POS cart line keeps touch targets at width $width', (
      tester,
    ) async {
      await _pumpAtWidth(
        tester,
        width: width,
        child: SizedBox(
          width: width < 480 ? width : 520,
          child: CartLineTile(
            line: _cartLine,
            onAdd: () {},
            onRemove: () {},
            onDelete: () {},
          ),
        ),
      );

      expect(find.textContaining('قهوة عربية'), findsOneWidget);
      expect(find.text('25.50 د.ل'), findsOneWidget);
      expect(tester.getSize(find.byTooltip('إضافة عنصر')).width, 48);
      expect(tester.getSize(find.byTooltip('إنقاص عنصر')).height, 48);
      expect(tester.getSize(find.byTooltip('حذف العنصر من السلة')).height, 48);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 390.0]) {
    testWidgets('compact order launcher stays usable at width $width', (
      tester,
    ) async {
      var tapCount = 0;

      await _pumpAtWidth(
        tester,
        width: width,
        child: SizedBox(
          width: width,
          child: PointyCompactOrderLauncher(
            title: 'البيع الحالي',
            lineCountLabel: 'عنصر واحد',
            totalLabel: '12.75 د.ل',
            actionLabel: 'مراجعة السلة',
            icon: Icons.shopping_cart_checkout_outlined,
            onPressed: () => tapCount += 1,
          ),
        ),
      );

      expect(find.text('البيع الحالي'), findsOneWidget);
      expect(find.text('عنصر واحد'), findsOneWidget);
      expect(find.text('12.75 د.ل'), findsOneWidget);
      expect(find.text('مراجعة السلة'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('مراجعة السلة'));
      await tester.pump();

      expect(tapCount, 1);
    });
  }

  for (final width in [390.0, 768.0]) {
    testWidgets('POS sale session switcher is usable at width $width', (
      tester,
    ) async {
      var started = false;
      int? selectedSessionId;
      int? discardedSessionId;

      await _pumpAtWidth(
        tester,
        width: width,
        child: SizedBox(
          width: width,
          child: PosSaleSessionSwitcher(
            sessions: const [
              PosSaleSessionSummary(
                id: 1,
                number: 1,
                lineCount: 1,
                itemCount: 2,
                subtotal: 25.5,
                total: 25.5,
                isActive: false,
                customerName: 'عميل سريع',
              ),
              PosSaleSessionSummary(
                id: 2,
                number: 2,
                lineCount: 1,
                itemCount: 1,
                subtotal: 2.75,
                total: 2.75,
                isActive: true,
                customerName: null,
              ),
            ],
            canStartNewSession: true,
            isLocked: false,
            onStartNewSession: () => started = true,
            onSelectSession: (id) => selectedSessionId = id,
            onDiscardSession: (id) => discardedSessionId = id,
          ),
        ),
      );

      expect(find.text('فاتورة 2'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('فاتورة 2'));
      await tester.pumpAndSettle();

      expect(find.text('الفواتير المفتوحة'), findsOneWidget);
      expect(find.text('فاتورة جديدة'), findsOneWidget);
      expect(find.text('فاتورة 1'), findsOneWidget);
      expect(find.textContaining('عميل سريع'), findsOneWidget);

      await tester.tap(find.text('فاتورة جديدة'));
      await tester.pumpAndSettle();
      expect(started, isTrue);

      await tester.tap(find.text('فاتورة 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('فاتورة 1'));
      await tester.pumpAndSettle();
      expect(selectedSessionId, 1);

      await tester.tap(find.text('فاتورة 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();

      // Discarding a parked sale now asks for confirmation first.
      expect(discardedSessionId, isNull);
      await tester.tap(find.text('تجاهل'));
      await tester.pumpAndSettle();

      expect(discardedSessionId, 1);
    });
  }

  testWidgets('active catalog card omits the redundant availability pill', (
    tester,
  ) async {
    await _pumpAtWidth(
      tester,
      width: 768,
      child: SizedBox(
        width: 220,
        height: 236,
        child: ProductTile(product: _longNameProduct, onTap: () {}),
      ),
    );

    expect(find.text('متاح'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog card flags inactive products and shows in-cart count', (
    tester,
  ) async {
    await _pumpAtWidth(
      tester,
      width: 768,
      child: SizedBox(
        width: 220,
        height: 236,
        child: ProductTile(
          product: _inactiveProduct,
          onTap: () {},
          cartQuantity: 3,
        ),
      ),
    );

    expect(find.text('متوقف'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.byIcon(Icons.add_shopping_cart_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('purchasing card surfaces low-stock status', (tester) async {
    await _pumpAtWidth(
      tester,
      width: 768,
      child: SizedBox(
        width: 220,
        height: 236,
        child: ProductTile.variant(
          variant: _lowStockVariant,
          onTap: () {},
          showPrice: false,
          showStock: true,
        ),
      ),
    );

    expect(find.text('منخفض'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpAtWidth(
  WidgetTester tester, {
  required double width,
  required Widget child,
}) async {
  tester.view.physicalSize = Size(width, 844);
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
          body: Center(child: SingleChildScrollView(child: child)),
        ),
      ),
    ),
  );
}

const _longNameProduct = Product(
  id: 1,
  name: 'قهوة عربية فاخرة بحبوب محمصة وطازجة للاختبار الطويل',
  quantityOnHand: 12,
  defaultVariant: ProductVariant(
    id: 10,
    productId: 1,
    sku: 'COFFEE-LONG-001',
    unitPrice: 12.75,
    productName: 'قهوة عربية فاخرة بحبوب محمصة وطازجة للاختبار الطويل',
  ),
);

const _cartLine = CartLine(
  quantity: 2,
  variant: ProductVariant(
    id: 10,
    productId: 1,
    sku: 'COFFEE-LONG-001',
    unitPrice: 12.75,
    productName: 'قهوة عربية فاخرة بحبوب محمصة وطازجة للاختبار الطويل',
  ),
);

const _inactiveProduct = Product(
  id: 2,
  name: 'منتج متوقف عن البيع',
  quantityOnHand: 0,
  isActive: false,
  defaultVariant: ProductVariant(
    id: 20,
    productId: 2,
    sku: 'INACTIVE-AA',
    unitPrice: 9.50,
    productName: 'منتج متوقف عن البيع',
  ),
);

const _lowStockVariant = ProductVariant(
  id: 30,
  productId: 3,
  sku: 'LOW-AA',
  unitPrice: 5.00,
  productName: 'صنف مخزونه منخفض',
  displayName: 'صنف مخزونه منخفض',
  quantityOnHand: 4,
);
