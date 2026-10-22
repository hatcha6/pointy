import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bulk_price_preview.dart';
import 'package:pointy_frontend/src/features/catalog/views/bulk_price/bulk_price_history_sheet.dart';

import 'bulk_price_test_support.dart';

void main() {
  Future<bool?> openSheet(
    WidgetTester tester,
    FakeBulkPriceRepository repository,
  ) async {
    bool? reverted;
    await tester.pumpWidget(
      bulkPriceApp(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  reverted = await showBulkPriceHistorySheet(
                    context,
                    catalogRepository: repository,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return reverted;
  }

  testWidgets('the sheet spans the phone width and lists each change', (
    tester,
  ) async {
    await setSurface(tester, const Size(375, 812));
    final repository = FakeBulkPriceRepository()
      ..history = Ok([
        bulkRecord(id: 3, changed: 128),
        bulkRecord(
          id: 2,
          changed: 42,
          revertedAt: DateTime(2026, 10, 17),
          revert: const BulkPriceRevertSummary(restored: 40, skipped: 2),
        ),
      ]);
    await openSheet(tester, repository);

    expect(find.text('128 سعرًا'), findsOneWidget);
    expect(find.text('تم التراجع'), findsOneWidget);
    final sheet = tester.getSize(find.byType(BottomSheet));
    expect(sheet.width, 375);
    // Only the change not yet undone offers an undo.
    expect(find.byKey(const ValueKey('bulk_price_revert_3')), findsOneWidget);
    expect(find.byKey(const ValueKey('bulk_price_revert_2')), findsNothing);
  });

  testWidgets('undo confirms, calls the server and reports the outcome', (
    tester,
  ) async {
    await setSurface(tester, const Size(800, 900));
    final repository = FakeBulkPriceRepository()
      ..history = Ok([bulkRecord(id: 3)]);
    await openSheet(tester, repository);

    await tester.tap(find.byKey(const ValueKey('bulk_price_revert_3')));
    await tester.pumpAndSettle();
    expect(find.text('التراجع عن هذا التعديل؟'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'تراجع'));
    await tester.pumpAndSettle();

    expect(repository.revertCalls, [3]);
    expect(find.textContaining('استُعيد 2 سعرًا'), findsOneWidget);
  });
}
