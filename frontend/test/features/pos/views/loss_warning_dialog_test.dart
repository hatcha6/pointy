import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/features/pos/views/loss_warning_dialog.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';

/// A sale below cost, as the till tells it.
///
/// Every reader is told WHICH line is below cost. Only a reader who may see
/// cost is told by how much: the loss is the cost less a total the cashier
/// typed, so a loss on screen is the cost on screen.
void main() {
  // The same line as the server sends it to a reader who may see cost, and
  // as it sends it to everyone else.
  const priced = SaleLossLine(
    productName: 'أرز',
    quantity: 1,
    unitPrice: 10,
    lineTotal: 5,
    unitCost: 6.4,
    lineCost: 6.4,
    lossAmount: 1.4,
  );
  const named = SaleLossLine(
    productName: 'أرز',
    quantity: 1,
    unitPrice: 10,
    lineTotal: 5,
  );

  // Held rather than awaited: awaiting it would wait for the dialog to close.
  late Future<bool?> pending;

  Future<void> open(
    WidgetTester tester, {
    required SaleLossLine line,
    required bool showAmounts,
    bool canSellAtLoss = false,
  }) async {
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
              onPressed: () => pending = showLossWarningDialog(
                context,
                lossLines: [line],
                canSellAtLoss: canSellAtLoss,
                showAmounts: showAmounts,
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

  testWidgets('a cashier is told which line is below cost, not by how much', (
    tester,
  ) async {
    await open(tester, line: named, showAmounts: false);

    expect(find.text('أرز: أقل من التكلفة'), findsOneWidget);
    expect(find.textContaining(': الخسارة'), findsNothing);
    // Refused, and sent to someone who can do something about it.
    expect(
      find.text(
        'بعض الأصناف أقل من تكلفتها، ولا تسمح إعدادات المتجر بالبيع بخسارة. '
        'راجع المدير.',
      ),
      findsOneWidget,
    );
    expect(find.text('مراجعة السلة'), findsOneWidget);
    expect(find.text('إتمام البيع'), findsNothing);
  });

  testWidgets('figures an older server still sends stay off a cashier screen', (
    tester,
  ) async {
    await open(tester, line: priced, showAmounts: false);

    expect(find.text('أرز: أقل من التكلفة'), findsOneWidget);
    expect(find.textContaining('1.40'), findsNothing);
    expect(find.textContaining('6.40'), findsNothing);
  });

  testWidgets('a reader who may see cost is told the loss on each line', (
    tester,
  ) async {
    await open(tester, line: priced, showAmounts: true);

    expect(find.text('أرز: الخسارة ${formatMoney(1.4)}'), findsOneWidget);
    expect(
      find.text('لا يمكن إتمام البيع لأن إعدادات المتجر تمنع البيع بخسارة.'),
      findsOneWidget,
    );
  });

  testWidgets('a cashier may still go on when the shop allows a loss', (
    tester,
  ) async {
    await open(tester, line: named, showAmounts: false, canSellAtLoss: true);

    expect(
      find.text(
        'نحن نبيع بعض عناصر السلة بخسارة. هل تريد إتمام البيع رغم ذلك؟',
      ),
      findsOneWidget,
    );
    expect(find.text('أرز: أقل من التكلفة'), findsOneWidget);

    await tester.tap(find.text('إتمام البيع'));
    await tester.pumpAndSettle();

    expect(await pending, isTrue);
  });
}
