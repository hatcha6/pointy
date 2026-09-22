import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/features/pos/views/cart_line_tile.dart';

/// The row that carries cost, margin and the reprice affordance.
///
/// The first version of it was gated on having a cost to show, which hid the
/// reprice link on every product the shop had never bought and on every line
/// while cost was hidden — nearly all of them, and exactly the lines a cashier
/// is most likely to haggle over. It was caught by looking at the POS preview,
/// and these keep it caught.
void main() {
  ProductVariant variant() => const ProductVariant(
    id: 7,
    productId: 1,
    sku: 'RICE-1',
    unitPrice: 10,
    productName: 'أرز',
    displayName: 'أرز',
    fullName: 'أرز',
    isDefault: true,
  );

  Widget harness(CartLineTile tile) => MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: tile)),
  );

  CartLine line({double? manualUnitPrice}) => CartLine.create(
    variant: variant(),
    quantity: 1,
    manualUnitPrice: manualUnitPrice,
  );

  // The reprice affordance lives on the per-unit price itself: a pencil on
  // a row of its own spent a whole row offering one action.
  final editKey = find.byKey(const ValueKey('order_line_unit_price_tap'));

  testWidgets('the price is tappable with no cost to display', (tester) async {
    await tester.pumpWidget(
      harness(
        CartLineTile(line: line(), onAdd: null, onRemove: null, onEditPrice: () {}),
      ),
    );

    expect(editKey, findsOneWidget);
  });

  testWidgets('the price is plain text without the permission', (tester) async {
    // onEditPrice is null for anybody without `sales.override_line_price`.
    await tester.pumpWidget(
      harness(CartLineTile(line: line(), onAdd: null, onRemove: null)),
    );

    expect(editKey, findsNothing);
  });

  testWidgets('cost and margin appear once cost is revealed', (tester) async {
    await tester.pumpWidget(
      harness(
        CartLineTile(
          line: line(),
          onAdd: null,
          onRemove: null,
          unitCost: 6,
        ),
      ),
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    // findRichText, because cost and margin are one Text.rich run: two
    // separate chips wrapped the row onto a second line on a narrow cart.
    expect(
      find.textContaining(l10n.cartLineCostLabel('6.00 د.ل'),
          findRichText: true),
      findsOneWidget,
    );
    // 10.00 sale − 6.00 cost.
    expect(
      find.textContaining(l10n.cartLineMarginLabel('4.00 د.ل'),
          findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('no cost row when cost is hidden', (tester) async {
    // The default state of every till: the permission decides who MAY see it,
    // F9 decides when, and a customer leaning over the counter sees neither.
    await tester.pumpWidget(
      harness(CartLineTile(line: line(), onAdd: null, onRemove: null)),
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(
      find.textContaining(l10n.cartLineCostLabel(''), findRichText: true),
      findsNothing,
    );
  });

  testWidgets('a repriced line is badged with what it used to cost', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        CartLineTile(
          line: line(manualUnitPrice: 7.25),
          onAdd: null,
          onRemove: null,
        ),
      ),
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(
      find.textContaining(l10n.cartLineRepricedBadge),
      findsOneWidget,
    );
    // "changed" without "from what" is not something a manager can check.
    expect(find.textContaining('10.00'), findsOneWidget);
  });

  testWidgets('everything at once survives a narrow till', (tester) async {
    // A cart pane on a compact till is ~300 logical pixels wide, and a line
    // can carry a full-width unit bar, a cost, a margin, a repriced badge and
    // a tappable price all at once. It wraps; it must not overflow.
    tester.view.physicalSize = const Size(300, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      harness(
        CartLineTile(
          line: line(manualUnitPrice: 7.25),
          onAdd: null,
          onRemove: null,
          unitCost: 6,
          onEditPrice: () {},
          onSwitchUnit: () {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(editKey, findsOneWidget);
  });
}
