import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/bulk_tracking_change.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/bulk_tracking_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/bulk_tracking/bulk_tracking_screen.dart';

import '../view_models/bulk_tracking_view_model_test.dart';
import 'bulk_price_test_support.dart';

void main() {
  Future<(BulkTrackingViewModel, FakeTrackingRepository)> pump(
    WidgetTester tester,
  ) async {
    await setSurface(tester, const Size(900, 1400));
    final repository = FakeTrackingRepository([
      ...changeRows(6, emptyEvery: 3),
      const BulkTrackingRow(
        product: 90,
        name: 'هاتف',
        outcome: BulkTrackingOutcome.blocked,
        message: 'لا يمكن تحويله لأنه يُتتبَّع بالرقم التسلسلي',
      ),
    ]);
    final viewModel = BulkTrackingViewModel(
      catalogRepository: repository,
      batchSize: 2,
    );
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(
      bulkPriceApp(
        BulkTrackingScreen(catalogRepository: repository, viewModel: viewModel),
      ),
    );
    await tester.pumpAndSettle();
    return (viewModel, repository);
  }

  Future<void> choose(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'nothing can be applied before a change is chosen and previewed',
    (tester) async {
      await pump(tester);
      expect(
        find.text('اختر تغييرًا واحدًا على الأقل: التتبّع أو التذكير.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('bulk_tracking_apply')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('the empty-shelf warning and checkbox decide what is sent', (
    tester,
  ) async {
    final (viewModel, repository) = await pump(tester);
    await choose(tester, 'bulk_tracking_expiry');
    await choose(tester, 'bulk_tracking_preview_button');

    expect(
      find.byKey(const ValueKey('bulk_tracking_empty_shelf_warning')),
      findsOneWidget,
    );
    final checkbox = find.byKey(const ValueKey('bulk_tracking_exclude_empty'));
    expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
    expect(find.text('تطبيق على 4 منتجًا'), findsOneWidget);

    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    expect(find.text('تطبيق على 6 منتجًا'), findsOneWidget);
    await tester.tap(checkbox);
    await tester.pumpAndSettle();

    // The refused row's reason is shown on the refused list.
    await choose(tester, 'bulk_tracking_view_blocked');
    expect(
      find.text('لا يمكن تحويله لأنه يُتتبَّع بالرقم التسلسلي'),
      findsOneWidget,
    );

    await choose(tester, 'bulk_tracking_apply');
    expect(find.textContaining('4'), findsWidgets);
    await choose(tester, 'bulk_tracking_confirm_apply');

    expect(repository.applyCalls, [
      [1, 2],
      [4, 5],
    ]);
    expect(viewModel.result.done, 4);
    expect(find.byKey(const ValueKey('bulk_tracking_result')), findsOneWidget);
  });
}
