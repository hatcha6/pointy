import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_draft_pane.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// The line tile's dialogs, opened and CLOSED the way a buyer closes them.
///
/// Opening a dialog is the easy half; the half that breaks is the teardown —
/// a controller disposed while its field is still mounted, or a widget still
/// depending on an inherited widget that is going away.
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
    ValueChanged<double>? onLineTotalEntry,
    ValueChanged<double>? onQuantityChanged,
    VoidCallback? onChangePrices,
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
            enabled: true,
            onAdd: () async {},
            onRemove: () {},
            onCostChanged: (_) {},
            onExpiryDateChanged: (_) {},
            onLineTotalEntry: onLineTotalEntry,
            onQuantityChanged: onQuantityChanged,
            onChangePrices: onChangePrices,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.delegate.load(const Locale('ar'));
  }

  const line = PurchaseDraftLine(variant: variant, quantity: 4, unitCost: 10);

  group('the line-total dialog', () {
    testWidgets('opens from the cost field and divides by the quantity', (
      tester,
    ) async {
      double? entered;
      final l10n = await pumpTile(
        tester,
        line,
        onLineTotalEntry: (value) => entered = value,
      );

      await tester.tap(find.byIcon(Icons.functions));
      await tester.pumpAndSettle();
      expect(find.text(l10n.purchaseLineTotalEntryTitle), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, '40.00'),
        '50',
      );
      await tester.tap(find.text(l10n.confirmButton));
      await tester.pumpAndSettle();

      expect(entered, 50);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cancelling leaves nothing behind', (tester) async {
      double? entered;
      final l10n = await pumpTile(
        tester,
        line,
        onLineTotalEntry: (value) => entered = value,
      );

      await tester.tap(find.byIcon(Icons.functions));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.cancelButton));
      await tester.pumpAndSettle();

      expect(entered, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dismissing by the barrier is clean', (tester) async {
      await pumpTile(tester, line, onLineTotalEntry: (_) {});

      await tester.tap(find.byIcon(Icons.functions));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('opening it twice in a row is clean', (tester) async {
      final l10n = await pumpTile(tester, line, onLineTotalEntry: (_) {});

      for (var i = 0; i < 2; i += 1) {
        await tester.tap(find.byIcon(Icons.functions));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.cancelButton));
        await tester.pumpAndSettle();
      }

      expect(tester.takeException(), isNull);
    });

    testWidgets('is absent when the line cannot accept one', (tester) async {
      await pumpTile(tester, line);

      expect(find.byIcon(Icons.functions), findsNothing);
    });
  });

  group('the quantity dialog', () {
    testWidgets('opens from the stepper and applies', (tester) async {
      double? quantity;
      final l10n = await pumpTile(
        tester,
        line,
        onQuantityChanged: (value) => quantity = value,
      );

      await tester.tap(find.text('4'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '9');
      await tester.tap(find.text(l10n.confirmButton));
      await tester.pumpAndSettle();

      expect(quantity, 9);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cancelling is clean', (tester) async {
      final l10n = await pumpTile(tester, line, onQuantityChanged: (_) {});

      await tester.tap(find.text('4'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.cancelButton));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('the tile itself', () {
    testWidgets('tapping the pricing summary opens pricing', (tester) async {
      var opened = 0;
      final l10n = await pumpTile(
        tester,
        line,
        onChangePrices: () => opened += 1,
      );

      // The selling-price line itself is the target — the whole summary is
      // tappable so the answer and the fix are one gesture.
      await tester.tap(
        find.text(l10n.purchaseLineSellingPrice('10.00 د.ل')),
      );
      await tester.pumpAndSettle();

      expect(opened, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a disposed tile leaves no live controllers', (tester) async {
      await pumpTile(tester, line, onLineTotalEntry: (_) {});

      // Replace the tile entirely: its controllers and focus nodes must tear
      // down without anything still depending on them.
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
