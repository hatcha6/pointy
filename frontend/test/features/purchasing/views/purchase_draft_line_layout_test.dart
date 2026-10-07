import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_unit.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_draft_pane.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/order/order.dart';

/// A draft line in the 360px pane of a 1024×768 screen: the line is ~286px,
/// and it still has to give the cost — and what that cost means per piece —
/// room to be read.
void main() {
  const carton = ProductUnit(
    unit: UnitOfMeasure(id: 1, code: 'carton', name: 'كرتونة'),
    factorToBase: 12,
    price: 30,
  );
  final variant = ProductVariant(
    id: 11,
    productId: 5,
    sku: 'WTR-005',
    unitPrice: 3,
    productName: 'ماء معدني 500 مل',
    productDetail: Product(
      id: 5,
      name: 'ماء معدني 500 مل',
      quantityOnHand: 0,
      units: const [carton],
    ),
  );
  // 24 a carton of 12: two a piece.
  final cartonLine = PurchaseDraftLine(
    variant: variant,
    quantity: 4,
    unitCost: 24,
    unitCode: 'carton',
    unitLabel: 'كرتونة',
    unitFactor: 12,
  );

  Future<AppLocalizations> pumpLine(WidgetTester tester, double width) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              child: PurchaseDraftLineTile(
                line: cartonLine,
                enabled: true,
                onAdd: () async {},
                onRemove: () {},
                onCostChanged: (_) {},
                onUnitChanged: (_, _, _, _) {},
                onChangePrices: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.delegate.load(const Locale('ar'));
  }

  testWidgets('a narrow line gives the cost a row and pairs unit with count', (
    tester,
  ) async {
    final l10n = await pumpLine(tester, 294);

    // The per-piece helper is what tells a buyer "24" is the carton's cost.
    final helper = find.text(
      l10n.purchaseLineCostPerBaseHelper('2.00 د.ل', 'قطعة'),
    );
    expect(helper, findsOneWidget);
    expect(tester.getSize(helper).width, lessThan(260));

    // Cost above; unit and stepper share the row beneath it.
    final cost = find.widgetWithText(TextField, '24.00');
    final stepper = find.byType(PointyQuantityStepper);
    final unit = find.byType(DropdownButtonFormField<String>);
    expect(
      tester.getTopLeft(stepper).dy,
      greaterThan(tester.getBottomLeft(cost).dy),
    );
    expect(
      (tester.getCenter(stepper).dy - tester.getCenter(unit).dy).abs(),
      lessThan(8),
    );

    // No thumbnail: its 66px went to the name and the price line.
    expect(find.byType(PointyProductImageFrame), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a line with room keeps its thumbnail', (tester) async {
    await pumpLine(tester, 420);

    expect(find.byType(PointyProductImageFrame), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
