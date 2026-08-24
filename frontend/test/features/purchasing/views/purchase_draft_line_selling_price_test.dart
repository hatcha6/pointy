import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_draft_pane.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() {
  const variant = ProductVariant(
    id: 11,
    productId: 5,
    sku: 'COF-1',
    productName: 'قهوة',
    unitPrice: 10,
  );

  Future<AppLocalizations> pumpTile(
    WidgetTester tester,
    PurchaseDraftLine line, {
    PurchaseDiscountPreviewLine? previewLine,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Scaffold(
          body: PurchaseDraftLineTile(
            line: line,
            previewLine: previewLine,
            enabled: true,
            onAdd: () async {},
            onRemove: () {},
            onCostChanged: (_) {},
            onExpiryDateChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.delegate.load(const Locale('ar'));
  }

  testWidgets('shows the variant\'s selling price under the SKU', (
    tester,
  ) async {
    final l10n = await pumpTile(
      tester,
      const PurchaseDraftLine(variant: variant, quantity: 2, unitCost: 4),
    );

    expect(find.text('COF-1'), findsOneWidget);
    expect(
      find.text(l10n.purchaseLineSellingPrice('10.00 د.ل')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('qualifies the price with the base unit on a pack line', (
    tester,
  ) async {
    final l10n = await pumpTile(
      tester,
      const PurchaseDraftLine(
        variant: variant,
        quantity: 1,
        // 48 per carton of 12 = 4 per piece, still under the 10.00 price.
        unitCost: 48,
        unitCode: 'carton',
        unitLabel: 'كرتونة',
        unitFactor: 12,
      ),
    );

    expect(
      find.text(l10n.purchaseLineSellingPricePerUnit('10.00 د.ل', 'قطعة')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('warns when the cost has caught up with the selling price', (
    tester,
  ) async {
    await pumpTile(
      tester,
      const PurchaseDraftLine(variant: variant, quantity: 1, unitCost: 10.5),
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('compares a pack line per base unit, not per pack', (
    tester,
  ) async {
    // 60 per carton of 12 = 5 per piece: comfortably under the 10.00 price, so
    // comparing the raw pack cost would raise a false alarm.
    await pumpTile(
      tester,
      const PurchaseDraftLine(
        variant: variant,
        quantity: 1,
        unitCost: 60,
        unitCode: 'carton',
        unitLabel: 'كرتونة',
        unitFactor: 12,
      ),
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('measures the price against the landed cost when there is one', (
    tester,
  ) async {
    // The typed cost (8) clears the 10.00 price; shipping pushes the real cost
    // to 11, which does not.
    await pumpTile(
      tester,
      const PurchaseDraftLine(variant: variant, quantity: 1, unitCost: 8),
      previewLine: const PurchaseDiscountPreviewLine(
        productId: 5,
        variantId: 11,
        quantity: 1,
        unitCost: 8,
        lineTotal: 8,
        allocatedLandedCost: 3,
        effectiveUnitCost: 11,
      ),
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('calls out a product that was never priced', (tester) async {
    final l10n = await pumpTile(
      tester,
      const PurchaseDraftLine(
        variant: ProductVariant(
          id: 12,
          productId: 5,
          sku: 'NEW-1',
          unitPrice: 0,
        ),
        quantity: 1,
        unitCost: 4,
      ),
    );

    expect(find.text(l10n.purchaseLineNoSellingPrice), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });
}
