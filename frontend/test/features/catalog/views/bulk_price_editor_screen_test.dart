import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bulk_price_preview.dart';
import 'package:pointy_frontend/src/data/models/bulk_price_rule.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/bulk_price_editor_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/bulk_price/bulk_price_editor_screen.dart';

import 'bulk_price_test_support.dart';

void main() {
  Future<BulkPriceEditorViewModel> pumpEditor(
    WidgetTester tester,
    FakeBulkPriceRepository repository, {
    Size size = const Size(1280, 900),
    VoidCallback? onPricesChanged,
  }) async {
    await setSurface(tester, size);
    final viewModel = BulkPriceEditorViewModel(
      catalogRepository: repository,
      previewDebounce: Duration.zero,
    );
    addTearDown(viewModel.dispose);
    await viewModel.load();
    await tester.pumpWidget(
      bulkPriceApp(
        BulkPriceEditorScreen(
          catalogRepository: repository,
          viewModel: viewModel,
          onPricesChanged: onPricesChanged,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return viewModel;
  }

  Future<void> typeFirstStepValue(
    WidgetTester tester,
    BulkPriceEditorViewModel viewModel,
    String value,
  ) async {
    final key = viewModel.spec.steps.first.key;
    await tester.enterText(
      find.byKey(ValueKey('bulk_price_step_value_$key')),
      value,
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('apply stays off until the rules are complete and previewed', (
    tester,
  ) async {
    final repository = FakeBulkPriceRepository();
    final viewModel = await pumpEditor(tester, repository);

    FilledButton apply() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('bulk_price_apply')),
    );
    expect(apply().onPressed, isNull);
    expect(find.text('أكمل الحقول المعلّمة'), findsOneWidget);

    await typeFirstStepValue(tester, viewModel, '10');

    expect(repository.previewCalls, isNotEmpty);
    expect(apply().onPressed, isNotNull);
    expect(find.text('تطبيق على 2 صنف'), findsOneWidget);
    expect(find.text('كولا'), findsOneWidget);
    expect(find.text('أقل من التكلفة'), findsOneWidget);
    expect(find.text('طُبّقت على 2'), findsOneWidget);
  });

  testWidgets('apply confirms, sends the fingerprint and offers an undo', (
    tester,
  ) async {
    var refreshed = 0;
    final repository = FakeBulkPriceRepository()
      ..fallbackPreview = Ok(
        bulkPreview(fingerprint: 'fp-9', summary: bulkSummary(warnings: 1)),
      );
    final viewModel = await pumpEditor(
      tester,
      repository,
      onPricesChanged: () => refreshed++,
    );
    await typeFirstStepValue(tester, viewModel, '10');

    await tester.tap(find.byKey(const ValueKey('bulk_price_apply')));
    await tester.pumpAndSettle();
    expect(find.text('تطبيق تعديل الأسعار؟'), findsOneWidget);
    expect(find.textContaining('صنفًا عليها تنبيهات'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('bulk_price_confirm_apply')));
    await tester.pumpAndSettle();

    expect(repository.applyCalls.single.fingerprint, 'fp-9');
    expect(refreshed, 1);
    expect(find.text('تم تعديل 2 سعرًا'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, 'تراجع'), findsOneWidget);
  });

  testWidgets('a stale refusal explains itself and writes nothing', (
    tester,
  ) async {
    var refreshed = 0;
    final repository = FakeBulkPriceRepository()
      ..applyResult = const Error(BulkPriceException(BulkPriceFailure.stale));
    final viewModel = await pumpEditor(
      tester,
      repository,
      onPricesChanged: () => refreshed++,
    );
    await typeFirstStepValue(tester, viewModel, '10');
    await tester.tap(find.byKey(const ValueKey('bulk_price_apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bulk_price_confirm_apply')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('تغيّرت بعض الأسعار منذ المعاينة'),
      findsOneWidget,
    );
    expect(refreshed, 0);
  });

  testWidgets('phone layout: rules and preview are tabs, nothing overflows', (
    tester,
  ) async {
    final repository = FakeBulkPriceRepository();
    final viewModel = await pumpEditor(
      tester,
      repository,
      size: const Size(375, 812),
    );
    viewModel
      ..setScopeAll(false)
      ..addGroup(viewModel.spec.filter.key)
      ..setStepConditional(viewModel.spec.steps.first.key, true);
    viewModel.updateStep(
      viewModel.spec.steps.first.key,
      (step) => step.copyWith(value: '10'),
    );
    await tester.pumpAndSettle();
    // Scroll the whole rules pane: every row must lay out at phone width.
    await tester.drag(find.byType(ListView).first, const Offset(0, -3000));
    await tester.pumpAndSettle();

    expect(find.text('القواعد'), findsOneWidget);
    await tester.tap(find.text('المعاينة').first);
    await tester.pumpAndSettle();
    // Three conditions are still blank (category, the group's, the step's):
    // the preview says so rather than guessing.
    expect(
      find.text('أكمل 3 من الحقول المعلّمة لعرض المعاينة.'),
      findsOneWidget,
    );
    expect(repository.previewCalls, isEmpty);
  });

  testWidgets('cost tools are hidden from a reader who cannot see cost', (
    tester,
  ) async {
    final repository = FakeBulkPriceRepository()..costVisible = false;
    await pumpEditor(tester, repository);
    expect(
      find.byKey(const ValueKey('bulk_price_never_below_cost')),
      findsNothing,
    );
    expect(find.text('التكلفة + ‎25%‎'), findsNothing);
    expect(BulkPriceField.cost.needsCost, isTrue);
  });
}
