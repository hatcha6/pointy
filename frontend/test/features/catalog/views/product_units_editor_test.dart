import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product_unit.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_units_editor.dart';

void main() {
  const box = UnitOfMeasure(id: 1, code: 'box', name: 'صندوق');
  const carton = UnitOfMeasure(id: 2, code: 'carton', name: 'كرتون');

  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  // Pumps the editor and returns a getter for the latest emitted unit list so
  // tests can assert on what would be sent to the API.
  Future<List<ProductUnit> Function()> pumpEditor(
    WidgetTester tester, {
    required List<ProductUnit> units,
  }) async {
    var latest = units;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProductUnitsEditor(
              availableUnits: const [box, carton],
              baseUnitCode: 'piece',
              units: units,
              defaultSaleUnit: '',
              defaultPurchaseUnit: '',
              onUnitsChanged: (value) => latest = value,
              onDefaultSaleChanged: (_) {},
              onDefaultPurchaseChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return () => latest;
  }

  testWidgets('adds a typed barcode as a chip and emits it', (tester) async {
    final latest = await pumpEditor(
      tester,
      units: const [ProductUnit(unit: box, factorToBase: 6)],
    );

    final field = find.widgetWithText(
      TextField,
      l10n.productUnitBarcodeAddHint,
    );
    expect(field, findsOneWidget);
    await tester.enterText(field, '600100200');

    final addButton = find.byTooltip(l10n.productUnitBarcodeAddTooltip);
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(InputChip, '600100200'), findsOneWidget);
    expect(latest().single.barcodes, ['600100200']);
  });

  testWidgets('removes a barcode chip and emits the shorter list', (
    tester,
  ) async {
    final latest = await pumpEditor(
      tester,
      units: const [
        ProductUnit(
          unit: box,
          factorToBase: 6,
          barcodes: ['600100200', '600100201'],
        ),
      ],
    );

    expect(find.widgetWithText(InputChip, '600100200'), findsOneWidget);
    // Tap the chip's delete affordance, located by its tooltip so the test is
    // independent of whatever delete icon the chip theme uses.
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(InputChip, '600100200'),
        matching: find.byTooltip(l10n.productUnitBarcodeRemoveTooltip),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(InputChip, '600100200'), findsNothing);
    expect(latest().single.barcodes, ['600100201']);
  });

  testWidgets('rejects a barcode already used by another unit', (tester) async {
    final latest = await pumpEditor(
      tester,
      units: const [
        ProductUnit(unit: box, factorToBase: 6, barcodes: ['555']),
        ProductUnit(unit: carton, factorToBase: 12),
      ],
    );

    // The second unit card is the carton; try to reuse the box's code.
    final cartonField = find
        .widgetWithText(TextField, l10n.productUnitBarcodeAddHint)
        .at(1);
    await tester.ensureVisible(cartonField);
    await tester.enterText(cartonField, '555');

    final cartonAdd = find.byTooltip(l10n.productUnitBarcodeAddTooltip).at(1);
    await tester.ensureVisible(cartonAdd);
    await tester.tap(cartonAdd);
    await tester.pump();

    // Conflict is surfaced and the carton never gains the duplicate code.
    expect(find.text(l10n.productUnitBarcodeConflict('صندوق')), findsOneWidget);
    expect(latest()[1].barcodes, isEmpty);
  });
}
