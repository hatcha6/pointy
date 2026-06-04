import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/features/pos/views/cart_line_tile.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/order/order.dart';
import 'package:pointy_frontend/src/shared/product_tile.dart';

void main() {
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
      expect(find.text('متاح'), findsOneWidget);
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
