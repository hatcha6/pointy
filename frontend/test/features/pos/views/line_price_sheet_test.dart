import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/features/pos/views/line_price_sheet.dart';

/// Changing what one line sells for, before the sale.
///
/// The alternative a shop had was walking to the products screen mid-sale,
/// which changes the price for every customer rather than this one.
void main() {
  CartLine line({double? manualUnitPrice}) => CartLine.create(
    variant: const ProductVariant(
      id: 7,
      productId: 1,
      sku: 'RICE-1',
      unitPrice: 10,
      productName: 'أرز',
      displayName: 'أرز',
      fullName: 'أرز',
      isDefault: true,
    ),
    quantity: 1,
    manualUnitPrice: manualUnitPrice,
  );

  // What the open sheet will resolve to, once something closes it.
  //
  // Held in a variable rather than RETURNED, which is the whole reason this
  // reads oddly: an `async` function that returns a Future has it flattened by
  // Dart, so `await open(...)` would wait for the dialog to CLOSE — which
  // cannot happen while the test is blocked waiting for it. That is a test
  // that hangs forever rather than one that fails.
  late Future<double?> pending;

  Future<void> open(
    WidgetTester tester, {
    required CartLine cartLine,
    double? unitCost,
  }) async {
    // A desktop-sized window, so showAdaptiveFormSurface takes its dialog
    // presentation. Below the desktop breakpoint it opens a draggable bottom
    // sheet, whose animation never settles under pumpAndSettle — the till this
    // is built for is a desktop anyway.
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => pending = showLinePriceSheet(
                context,
                line: cartLine,
                unitCost: unitCost,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  final field = find.byKey(const ValueKey('line_price_field'));

  testWidgets('opens focused with the whole price selected', (tester) async {
    // A cashier opens this to say a NEW number, essentially always. Clearing
    // the field by hand first is a step, and a step at the counter with a
    // customer waiting.
    await open(tester, cartLine: line());

    final state = tester.state<EditableTextState>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
    expect(state.widget.focusNode.hasFocus, isTrue);
    expect(state.textEditingValue.text, '10.00');
    expect(
      state.textEditingValue.selection,
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
  });

  testWidgets('typing replaces the price rather than appending', (
    tester,
  ) async {
    await open(tester, cartLine: line());
    await tester.enterText(field, '6.5');
    await tester.tap(find.byKey(const ValueKey('line_price_save')));
    await tester.pumpAndSettle();

    expect(await pending, 6.5);
  });

  testWidgets('zero is a real price', (tester) async {
    // A warranty replacement handed over at no charge. Only a missing or
    // negative number is refused.
    await open(tester, cartLine: line());
    await tester.enterText(field, '0');
    await tester.tap(find.byKey(const ValueKey('line_price_save')));
    await tester.pumpAndSettle();

    expect(await pending, 0);
  });

  testWidgets('a minus sign cannot even be typed', (tester) async {
    // DecimalTextInputFormatter only admits digits and one separator, so a
    // negative price is unreachable rather than merely refused. Asserted so
    // the guard below is not the only thing standing between a cashier and a
    // line that pays the customer.
    await open(tester, cartLine: line());
    await tester.enterText(field, '-1');
    await tester.pump();

    expect(find.text('-1'), findsNothing);
  });

  testWidgets('an empty price is refused with a reason', (tester) async {
    // The reachable invalid state: the field cleared and nothing typed.
    await open(tester, cartLine: line());
    await tester.enterText(field, '');
    await tester.tap(find.byKey(const ValueKey('line_price_save')));
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.editLinePriceInvalid), findsOneWidget);
  });

  testWidgets('a price under cost warns without blocking', (tester) async {
    // Whether selling under cost is allowed at all is the shop's
    // prevent_selling_at_loss setting, enforced server-side at checkout. This
    // is so the cashier knows before the customer does.
    await open(tester, cartLine: line(), unitCost: 8);
    await tester.enterText(field, '5');
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.editLinePriceBelowCostWarning), findsOneWidget);
    expect(
      tester.widget<FilledButton>(
        find.byKey(const ValueKey('line_price_save')),
      ).onPressed,
      isNotNull,
    );
  });

  testWidgets('reset is offered only on a line that was repriced', (
    tester,
  ) async {
    await open(tester, cartLine: line());
    expect(find.byKey(const ValueKey('line_price_reset')), findsNothing);
  });

  testWidgets('reset is distinct from cancelling', (tester) async {
    // Dismissing means "leave it as it was"; reset means "put it back on the
    // shop's price". Collapsing the two would make reset unreachable from a
    // sheet that can also be dismissed.
    await open(tester, cartLine: line(manualUnitPrice: 6.5));
    await tester.tap(find.byKey(const ValueKey('line_price_reset')));
    await tester.pumpAndSettle();

    expect(await pending, clearedLinePrice);
  });
}
