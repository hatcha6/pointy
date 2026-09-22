import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/features/pos/views/invoice_discount_sheet.dart';
// The sheet renders money through the shared formatter, so the expectations
// go through it too rather than hard-coding a symbol and a separator.
import 'package:pointy_frontend/src/shared/formatters.dart';

/// Taking a flat amount off the whole invoice, mid-sale.
///
/// The shop's ceiling is what the cashier feels here: the box refuses to save
/// past it, so a limit is met while the number is being typed rather than at
/// payment, in front of the customer. The server enforces the same ceiling —
/// this sheet is the courtesy, not the control.
void main() {
  // What the open sheet resolves to once something closes it. Held rather than
  // returned: awaiting the Future here would block the test on a dialog it is
  // itself responsible for closing.
  late Future<double?> pending;

  Future<void> open(
    WidgetTester tester, {
    double currentAmount = 0,
    double roomOnTheSale = 100,
    double? limit,
  }) async {
    // A desktop-sized window so showAdaptiveFormSurface takes its dialog
    // presentation; the bottom-sheet variant never settles under pumpAndSettle.
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
              onPressed: () => pending = showInvoiceDiscountSheet(
                context,
                currentAmount: currentAmount,
                roomOnTheSale: roomOnTheSale,
                limit: limit,
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

  final field = find.byKey(const ValueKey('invoice_discount_field'));
  final save = find.byKey(const ValueKey('invoice_discount_save'));
  final clear = find.byKey(const ValueKey('invoice_discount_clear'));

  testWidgets('a typed amount comes back to the till', (tester) async {
    await open(tester);

    await tester.enterText(field, '7.50');
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(await pending, 7.50);
  });

  testWidgets('opens empty when there is no discount yet', (tester) async {
    // Not '0.00' — a cashier reaching for this box wants to type a number, not
    // delete a placeholder first.
    await open(tester);

    final state = tester.state<EditableTextState>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
    expect(state.textEditingValue.text, '');
  });

  testWidgets('opens with the current amount selected for replacement', (
    tester,
  ) async {
    await open(tester, currentAmount: 5);

    final state = tester.state<EditableTextState>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
    expect(state.textEditingValue.text, '5.00');
    expect(
      state.textEditingValue.selection,
      const TextSelection(baseOffset: 0, extentOffset: 4),
    );
  });

  testWidgets('refuses to save past the shop ceiling', (tester) async {
    await open(tester, limit: 20);

    await tester.enterText(field, '20.01');
    await tester.pump();

    expect(tester.widget<FilledButton>(save).onPressed, isNull);
  });

  testWidgets('saves an amount exactly at the ceiling', (tester) async {
    await open(tester, limit: 20);

    await tester.enterText(field, '20');
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(await pending, 20);
  });

  testWidgets('names the ceiling so the cashier knows the rule', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await open(tester, limit: 20);

    expect(
      find.text(l10n.invoiceDiscountLimitHint(formatMoney(20))),
      findsOneWidget,
    );
  });

  testWidgets('says so when the cart cannot carry the whole discount', (
    tester,
  ) async {
    // Not an error: the server applies what the sale is worth. Refusing a round
    // number a cashier meant as "make it free" would be worse at a counter.
    await open(tester, roomOnTheSale: 12);

    await tester.enterText(field, '50');
    await tester.pump();

    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(find.byType(SnackBar), findsNothing);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(
      find.text(l10n.invoiceDiscountCappedNotice(formatMoney(12))),
      findsOneWidget,
    );
  });

  testWidgets('clearing returns zero, not null', (tester) async {
    // Null means "the cashier backed out"; zero means "take the discount off".
    // Collapsing the two would make removing a discount impossible from a sheet
    // that can also be dismissed.
    await open(tester, currentAmount: 5);

    await tester.tap(clear);
    await tester.pumpAndSettle();

    expect(await pending, 0);
  });

  testWidgets('there is nothing to clear when no discount is set', (
    tester,
  ) async {
    await open(tester);

    expect(clear, findsNothing);
  });

  testWidgets('cancelling changes nothing', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await open(tester, currentAmount: 5);

    await tester.enterText(field, '9');
    await tester.pump();
    await tester.tap(find.text(l10n.cancelButton));
    await tester.pumpAndSettle();

    expect(await pending, isNull);
  });
}
