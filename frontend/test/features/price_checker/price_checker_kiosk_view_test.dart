import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/price_lookup_result.dart';
import 'package:pointy_frontend/src/features/price_checker/views/price_checker_kiosk_view.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: PointyTheme.light(),
    home: child,
  );
}

PriceCheckerKioskView _view(
  PriceCheckerKioskStatus status, {
  PriceLookupResult? result,
  String barcode = '',
}) {
  return PriceCheckerKioskView(
    status: status,
    result: result,
    barcode: barcode,
    shopName: 'بقالة الأمل',
    onManualEntry: () {},
    onExitRequested: () {},
  );
}

const _discounted = PriceLookupResult(
  found: true,
  barcode: '6001234500001',
  inStock: true,
  currency: 'د.ل',
  productName: 'قميص قطني كلاسيكي',
  variantName: 'مقاس L',
  sku: 'TEE-1',
  unit: 'PCS',
  originalPrice: '20.00',
  finalPrice: '18.00',
  discountTotal: '2.00',
  discountPercent: 10,
  hasDiscount: true,
  originalPriceDisplay: '20.00 د.ل',
  finalPriceDisplay: '18.00 د.ل',
);

void main() {
  // A spread of real-world price-checker screen sizes, including extremes.
  const sizes = <Size>[
    Size(480, 320), // tiny shelf verifier, landscape
    Size(360, 640), // phone-class, portrait
    Size(800, 480), // common 7" verifier
    Size(1280, 800), // monitor
    Size(1920, 1080), // wall display
  ];

  Future<void> pumpAt(WidgetTester tester, Size size, Widget child) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_wrap(child));
    await tester.pump();
  }

  testWidgets('found state shows price + name at every size with no overflow', (
    tester,
  ) async {
    for (final size in sizes) {
      await pumpAt(
        tester,
        size,
        _view(PriceCheckerKioskStatus.found, result: _discounted),
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'render error/overflow at $size',
      );
      expect(find.text('18.00 د.ل'), findsOneWidget);
      expect(find.text('قميص قطني كلاسيكي'), findsOneWidget);
      // Discount treatment: struck original price + a save badge. (Use the
      // exact badge text — "متوفّر"/in-stock also contains the "وفّر" substring.)
      expect(find.text('20.00 د.ل'), findsOneWidget);
      expect(find.text('وفّر 10٪'), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('idle / loading / not-found / disconnected render cleanly', (
    tester,
  ) async {
    for (final status in PriceCheckerKioskStatus.values) {
      if (status == PriceCheckerKioskStatus.found) continue;
      await pumpAt(
        tester,
        const Size(800, 480),
        _view(status, barcode: '6001234599999'),
      );
      expect(tester.takeException(), isNull, reason: 'render error in $status');
    }
    // Tear down the animated idle widget so its ticker is disposed cleanly.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('out-of-stock found product reads "out of stock"', (tester) async {
    const outOfStock = PriceLookupResult(
      found: true,
      barcode: '6001',
      inStock: false,
      currency: 'د.ل',
      productName: 'علبة شوكولاتة',
      finalPrice: '12.50',
      finalPriceDisplay: '12.50 د.ل',
      originalPriceDisplay: '12.50 د.ل',
    );
    await pumpAt(
      tester,
      const Size(800, 480),
      _view(PriceCheckerKioskStatus.found, result: outOfStock),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('غير متوفّر'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
