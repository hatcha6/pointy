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

  testWidgets(
    'the rejected amount error names the ceiling, not just "too big"',
    (tester) async {
      await _pumpHost(tester, onResult: (_) {});
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('record_payment_amount_field')),
        '50.00',
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      // The cashier is told the exact maximum (the 20.00 balance passed in), so
      // the correction is one edit away instead of a guess.
      expect(find.textContaining('20.00'), findsOneWidget);
      expect(find.textContaining('لا يتجاوز'), findsOneWidget);
    },
  );

  testWidgets('a supplier pay-out over the balance is told the balance', (
    tester,
  ) async {
    await _pumpSupplierHost(tester, onResult: (_) {});
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('record_payment_amount_field')),
      '250',
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    // The supplier call site passes no balance line, so the error is the only
    // place the 100.00 outstanding is ever named.
    expect(find.textContaining('100.00'), findsOneWidget);
  });

  testWidgets('the amount error clears as soon as the amount is edited', (
    tester,
  ) async {
    await _pumpHost(tester, onResult: (_) {});
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('record_payment_amount_field')),
      '50.00',
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('لا يتجاوز'), findsOneWidget);

    // Correcting the amount takes the error down with it — a stale red line
    // under a now-valid amount reads as "still wrong".
    await tester.enterText(
      find.byKey(const ValueKey('record_payment_amount_field')),
      '5.00',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('لا يتجاوز'), findsNothing);
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

  testWidgets(
    'supplier options offer cash/transfer/card/credit and a card pay-out '
    'resolves without scanning a terminal receipt',
    (tester) async {
      RecordPaymentResult? result;
      await _pumpSupplierHost(tester, onResult: (value) => result = value);
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();

      // Reference + notes + the disbursement proof toggle are all present.
      expect(find.text('مرجع اختياري'), findsOneWidget);
      expect(find.text('ملاحظات اختيارية'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('record_payment_print_proof_toggle')),
        findsOneWidget,
      );

      // The four supplier methods are offered in the dropdown menu.
      await tester.tap(
        find.byKey(const ValueKey('record_payment_method_field')),
      );
      await tester.pumpAndSettle();
      expect(find.text('نقد'), findsWidgets);
      expect(find.text('تحويل'), findsWidgets);
      expect(find.text('بطاقة'), findsWidgets);
      expect(find.text('رصيد المورد'), findsWidgets);

      // Pick card, then submit: a supplier card pay-out is money OUT, so there
      // is no shop-terminal receipt to scan — it must resolve directly.
      await tester.tap(find.text('بطاقة').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('record_payment_amount_field')),
        '30.00',
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.methodApiValue, 'card');
      expect(result!.cardReceiptUrl, isEmpty);
    },
  );
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

Future<void> _pumpSupplierHost(
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
              final l10n = AppLocalizations.of(context)!;
              final result = await showRecordPaymentDialog(
                context,
                title: 'دفعة مورد',
                maxAmount: 100,
                methods: supplierPaymentMethodOptions(l10n),
                showReference: true,
                showNotes: true,
                proofToggleLabel: l10n.supplierPaymentPrintProofLabel,
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
