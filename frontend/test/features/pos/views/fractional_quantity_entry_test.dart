import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/features/pos/views/cart_line_tile.dart';
import 'package:pointy_frontend/src/features/pos/views/unit_quantity_sheet.dart';
import 'package:pointy_frontend/src/features/pos/views/weight_entry_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/order/quantity_adjustment_dialog.dart';

/// Fractional quantities are a cashier's choice, allowed for every product.
/// These drive the actual entry dialogs to prove a plain (whole-number) product
/// now accepts a decimal quantity in both the quantity dialog and the UoM sheet,
/// and that a plain line's quantity is tap-to-type editable.
void main() {
  const pieceVariant = ProductVariant(
    id: 10,
    productId: 1,
    sku: 'PEN-1',
    unitPrice: 2,
    unit: 'piece',
    productName: 'قلم حبر',
  );

  testWidgets('quantity dialog accepts a fraction for a plain piece product '
      'and uses generic quantity wording (not "weight")', (tester) async {
    double? entered;
    await _pump(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            entered = await showWeightEntrySheet(
              context,
              variant: pieceVariant,
            );
          },
          child: const Text('open'),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // A plain piece product is not weighed: it shows "الكمية" (quantity), not
    // the weight prompt.
    expect(find.text('الكمية'), findsOneWidget);
    expect(find.text('أدخل الوزن'), findsNothing);

    await tester.enterText(find.byType(TextField), '2.5');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(entered, 2.5);
  });

  testWidgets('UoM sheet accepts a fraction on a whole-number unit', (
    tester,
  ) async {
    // A multi-unit product whose base unit (piece) and box unit are both
    // whole-number units — the sheet must still accept a typed fraction.
    final product = Product.fromJson({
      'id': 1,
      'name': 'مشروب غازي',
      'unit': 'piece',
      'units': [
        {
          'id': 3,
          'unit': 'box',
          'unit_detail': {
            'id': 9,
            'code': 'box',
            'name': 'صندوق',
            'abbreviation': 'صندوق',
            'allows_fractional': false,
          },
          'factor_to_base': '12',
          'price': null,
          'is_sellable': true,
          'is_purchasable': true,
        },
      ],
      'quantity_on_hand': 0,
    });

    UnitQuantitySelection? selection;
    await _pump(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            selection = await showUnitQuantitySheet(
              context,
              product: product,
              variant: pieceVariant,
            );
          },
          child: const Text('open'),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // It really is the multi-unit sheet (a box unit chip is offered).
    expect(find.textContaining('صندوق'), findsOneWidget);

    // The default unit is the whole-number base (piece); it now takes 2.5.
    await tester.enterText(find.byType(TextField), '2.5');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(selection, isNotNull);
    expect(selection!.quantity, 2.5);
    expect(selection!.unit.isBase, isTrue);
  });

  testWidgets('a plain piece cart line quantity is tap-to-type editable', (
    tester,
  ) async {
    const line = CartLine(quantity: 3, variant: pieceVariant);
    var editRequested = false;

    await _pump(
      tester,
      CartLineTile(
        line: line,
        onAdd: () {},
        onRemove: () {},
        onEditQuantity: () => editRequested = true,
      ),
    );

    // Tapping the quantity ("3") opens the editor — previously suppressed for
    // plain whole-piece lines.
    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();

    expect(editRequested, isTrue);
  });

  testWidgets(
    'returns/refunds: an adjustment line accepts a typed fractional quantity',
    (tester) async {
      double? changed;
      await _pump(
        tester,
        AdjustmentLineStepper(
          option: const AdjustmentLineOption(
            lineId: 1,
            title: 'قلم حبر',
            subtitle: 'الكمية 3',
            maxQuantity: 3,
            allowDecimal: true,
            decimalEntryTitle: 'الكمية',
          ),
          value: 0,
          onChanged: (value) => changed = value,
        ),
      );

      // Tapping the quantity opens the tap-to-type entry; a fraction sticks.
      await tester.tap(find.text('0'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1.5');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(changed, 1.5);
    },
  );
}

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
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
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}
