import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product_draft.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_draft.dart';
import 'package:pointy_frontend/src/features/catalog/views/low_stock_threshold_field.dart';
import 'package:pointy_frontend/src/shared/catalog/stock_status_label.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

ProductVariant _variant(Object? threshold) => ProductVariant.fromJson({
  'id': 1,
  'product': 1,
  'sku': 'V-1',
  'unit_price': '3.00',
  'low_stock_threshold': threshold,
});

ProductVariantDraft _draft(({double? value})? threshold) => ProductVariantDraft(
  productId: 1,
  sku: 'V-1',
  unitPrice: 3,
  lowStockThreshold: threshold,
);

void main() {
  group('ProductVariant.lowStockThreshold', () {
    test('reads the decimal string the API sends', () {
      expect(_variant('2.500').lowStockThreshold, 2.5);
      expect(_variant(null).lowStockThreshold, isNull);
    });

    test('an unwatched variant is never low', () {
      expect(_variant(null).isLowStock(0.5), isFalse);
    });

    test('a watched variant is low at or below its threshold', () {
      final variant = _variant('4.000');
      expect(variant.isLowStock(4), isTrue);
      expect(variant.isLowStock(4.001), isFalse);
    });

    test('survives the cart round trip', () {
      final restored = ProductVariant.fromJson(_variant('6.000').toCartJson());
      expect(restored.lowStockThreshold, 6);
    });
  });

  group('ProductVariantDraft.lowStockThreshold', () {
    test('omitted when the form did not show it, so the saved one stays', () {
      expect(_draft(null).toJson().containsKey('low_stock_threshold'), isFalse);
    });

    test('an explicit null clears it', () {
      final json = _draft((value: null)).toJson();
      expect(json.containsKey('low_stock_threshold'), isTrue);
      expect(json['low_stock_threshold'], isNull);
    });

    test('a number is sent with three places', () {
      expect(_draft((value: 1.25)).toJson()['low_stock_threshold'], '1.250');
    });

    test('a simple product sends it on its default variant', () {
      const draft = ProductDraft(
        variantSku: 'P-1',
        name: 'منتج',
        variantUnitPrice: 2,
        isActive: true,
        tracksExpiry: false,
        lowStockThreshold: (value: 12),
      );
      final defaultVariant =
          draft.toJson()['default_variant']! as Map<String, Object?>;
      expect(defaultVariant['low_stock_threshold'], '12.000');
    });
  });

  group('lowStockThresholdFromText', () {
    test('blank is not watched', () {
      expect(lowStockThresholdFromText('  '), isNull);
      expect(lowStockThresholdFromText('7'), 7);
      expect(lowStockThresholdText(null), '');
      expect(lowStockThresholdText(7), '7');
      expect(lowStockThresholdText(1.25), '1.250');
    });
  });

  group('StockStatusLabel', () {
    Future<void> pump(WidgetTester tester, StockStatusLabel label) {
      return tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: PointyTheme.light(),
          home: Scaffold(body: Center(child: label)),
        ),
      );
    }

    testWidgets('a small count is not low unless the variant says so', (
      tester,
    ) async {
      await pump(
        tester,
        const StockStatusLabel(quantity: 2, isActive: true, compact: true),
      );
      expect(find.text('متوفر'), findsOneWidget);

      await pump(
        tester,
        const StockStatusLabel(
          quantity: 2,
          isActive: true,
          isLow: true,
          compact: true,
        ),
      );
      expect(find.text('منخفض'), findsOneWidget);
    });

    testWidgets('an empty shelf is out, whatever the threshold', (
      tester,
    ) async {
      await pump(
        tester,
        const StockStatusLabel(
          quantity: 0,
          isActive: true,
          isLow: true,
          compact: true,
        ),
      );
      expect(find.text('نافد'), findsOneWidget);
    });
  });
}
