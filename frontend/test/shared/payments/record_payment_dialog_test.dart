import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/payments/record_payment_dialog.dart';

void main() {
  testWidgets('confirms a valid (cash) payment and returns the result', (
    tester,
  ) async {
    RecordPaymentResult? result;
    await _pumpHost(tester, onResult: (value) => result = value);
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    // Cash is the first method (no receipt scan), amount prefilled to the max.
    await tester.enterText(
      find.byKey(const ValueKey('record_payment_amount_field')),
      '12.00',
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.methodApiValue, 'cash');
    expect(result!.amount, 12.0);
    expect(result!.cardReceiptUrl, isEmpty);
    expect(result!.printProof, isFalse);
  });

  testWidgets('rejects an amount above the maximum and stays open', (
    tester,
  ) async {
    RecordPaymentResult? result;
    var resolved = false;
    await _pumpHost(
      tester,
      onResult: (value) {
        result = value;
        resolved = true;
      },
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('record_payment_amount_field')),
      '50.00',
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    // The dialog rejects the over-max amount: it stays open and never resolves.
    expect(resolved, isFalse);
    expect(result, isNull);
    expect(
      find.byKey(const ValueKey('record_payment_amount_field')),
      findsOneWidget,
    );
  });

  testWidgets('offers every method passed in (cash, card, transfer)', (
    tester,
  ) async {
    await _pumpHost(tester, onResult: (_) {});
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('record_payment_method_field')));
    await tester.pumpAndSettle();

    // Three customer methods are offered in the dropdown menu.
    expect(find.text('نقد'), findsWidgets);
    expect(find.text('بطاقة'), findsWidgets);
    expect(find.text('تحويل'), findsWidgets);
  });
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required ValueChanged<RecordPaymentResult?> onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () async {
              final result = await showRecordPaymentDialog(
                context,
                title: 'تحصيل',
                maxAmount: 20,
                methods: customerPaymentMethodOptions(
                  AppLocalizations.of(context)!,
                ),
              );
              onResult(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}
