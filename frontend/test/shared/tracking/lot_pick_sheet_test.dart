import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/stock_batch.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/tracking/lot_pick_sheet.dart';

/// The shared "which lots are leaving" sheet: optional, stopped lots marked
/// and listed first, and no confirming a choice that cannot cover the line.
void main() {
  testWidgets('choosing nothing is a valid answer', (tester) async {
    final result = await _open(tester, quantity: 3);

    expect(
      find.text('تلقائي: الأقرب انتهاءً من الدفعات الصالحة'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'تأكيد'));
    await tester.pumpAndSettle();

    expect(await result, {1: <int>[]});
  });

  testWidgets('expired and recalled lots are marked and come first', (
    tester,
  ) async {
    await _open(tester, quantity: 1);

    expect(find.text('محجورة'), findsOneWidget);
    expect(find.text('منتهية الصلاحية'), findsOneWidget);
    final good = tester.getTopLeft(find.text('GOOD')).dy;
    expect(tester.getTopLeft(find.text('RECALL')).dy, lessThan(good));
    expect(tester.getTopLeft(find.text('OLD')).dy, lessThan(good));
  });

  testWidgets('a choice that cannot cover the line holds the confirm', (
    tester,
  ) async {
    final result = await _open(tester, quantity: 5);

    await tester.tap(find.text('RECALL'));
    await tester.pumpAndSettle();
    expect(find.textContaining('فيها 4 فقط من 5'), findsOneWidget);
    final confirm = find.widgetWithText(FilledButton, 'تأكيد');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.text('GOOD'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect((await result)![1]!.toSet(), {2, 3});
  });
}

StockBatch _lot(
  int id,
  String code, {
  required double here,
  DateTime? expiry,
  String status = StockBatchStatus.active,
}) {
  final sellable = status == StockBatchStatus.active;
  return StockBatch(
    id: id,
    variantId: 5,
    code: code,
    displayCode: code,
    expiryDate: expiry,
    status: status,
    isSellable: sellable,
    isLocked: status == StockBatchStatus.quarantined,
    balances: [
      StockBatchBalance(
        id: id,
        batchId: id,
        warehouseId: 7,
        remainingQuantity: here,
      ),
    ],
  );
}

Future<Future<Map<int, List<int>>?>> _open(
  WidgetTester tester, {
  required double quantity,
}) async {
  final now = DateTime.now();
  Future<Result<StockBatchPage>> load(int variantId) async => Ok(
    StockBatchPage(
      batches: [
        _lot(2, 'GOOD', here: 3, expiry: DateTime(now.year + 1, 1, 1)),
        _lot(
          3,
          'RECALL',
          here: 4,
          expiry: DateTime(now.year + 2, 1, 1),
          status: StockBatchStatus.quarantined,
        ),
        _lot(
          4,
          'OLD',
          here: 1,
          expiry: now.subtract(const Duration(days: 10)),
          status: StockBatchStatus.expired,
        ),
      ],
    ),
  );

  late Future<Map<int, List<int>>?> result;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () {
              result = showLotPickSheet(
                context,
                title: 'حدّد الدفعات',
                message: 'رسالة',
                confirmLabel: 'تأكيد',
                lines: [
                  LotPickLine(
                    key: 1,
                    title: 'شراب',
                    quantity: quantity,
                    variantId: 5,
                  ),
                ],
                loadLots: load,
                warehouseId: 7,
              );
            },
            child: const Text('افتح'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('افتح'));
  await tester.pumpAndSettle();
  return result;
}
