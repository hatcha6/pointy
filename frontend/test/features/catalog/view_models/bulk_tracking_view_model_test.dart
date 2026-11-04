import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bulk_price_rule.dart';
import 'package:pointy_frontend/src/data/models/bulk_tracking_change.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/bulk_tracking_view_model.dart';

class FakeTrackingRepository extends CatalogRepository {
  FakeTrackingRepository(this.rows) : super(PosApiService());

  final List<BulkTrackingRow> rows;
  final List<List<int>> applyCalls = [];

  /// Calls (1-based) that fail with a network error.
  final Set<int> failCalls = {};
  BulkTrackingAction? lastAction;

  @override
  Future<Result<BulkTrackingPreview>> previewBulkTrackingChange({
    required BulkTrackingAction action,
    required BulkPriceGroup filter,
  }) async {
    lastAction = action;
    int count(BulkTrackingOutcome o) =>
        rows.where((r) => r.outcome == o).length;
    return Ok(
      BulkTrackingPreview(
        summary: BulkTrackingSummary(
          matched: rows.length,
          change: count(BulkTrackingOutcome.change),
          same: count(BulkTrackingOutcome.same),
          blocked: count(BulkTrackingOutcome.blocked),
          emptyShelf: rows.where((r) => r.isEmptyShelf).length,
        ),
        rows: rows,
      ),
    );
  }

  @override
  Future<Result<BulkTrackingApplyResult>> applyBulkTrackingChange({
    required BulkTrackingAction action,
    required BulkPriceGroup filter,
    required List<int> productIds,
  }) async {
    applyCalls.add(productIds);
    if (failCalls.contains(applyCalls.length)) {
      return Error(Exception('network'));
    }
    return Ok(BulkTrackingApplyResult(done: productIds.length));
  }
}

List<BulkTrackingRow> changeRows(int count, {int emptyEvery = 0}) => [
  for (var id = 1; id <= count; id++)
    BulkTrackingRow(
      product: id,
      name: 'منتج $id',
      outcome: BulkTrackingOutcome.change,
      warnings: emptyEvery > 0 && id % emptyEvery == 0
          ? const {BulkTrackingWarning.emptyShelf}
          : const {},
    ),
];

void main() {
  Future<BulkTrackingViewModel> previewed(
    FakeTrackingRepository repository, {
    VoidCallback? onChanged,
  }) async {
    final viewModel = BulkTrackingViewModel(
      catalogRepository: repository,
      onChanged: onChanged,
    );
    addTearDown(viewModel.dispose);
    viewModel.setTracking(BulkTrackingTarget.expiry);
    await viewModel.refreshPreview();
    return viewModel;
  }

  test('250 products go out as three sequential calls of 100/100/50', () async {
    final repository = FakeTrackingRepository(changeRows(250));
    var changed = 0;
    final viewModel = await previewed(repository, onChanged: () => changed++);

    await viewModel.apply();

    expect(repository.applyCalls.map((ids) => ids.length), [100, 100, 50]);
    expect(repository.applyCalls.first.first, 1);
    expect(repository.applyCalls.last.last, 250);
    expect(viewModel.result.done, 250);
    expect(viewModel.applyInterrupted, isFalse);
    expect(viewModel.progress, 1);
    expect(changed, 1);
  });

  test(
    'a network failure stops the run and resumes with what is left',
    () async {
      final repository = FakeTrackingRepository(changeRows(250))
        ..failCalls.add(2);
      var changed = 0;
      final viewModel = await previewed(repository, onChanged: () => changed++);

      await viewModel.apply();

      expect(repository.applyCalls.length, 2);
      expect(viewModel.applyInterrupted, isTrue);
      expect(viewModel.sentCount, 100);
      expect(viewModel.remainingCount, 150);
      expect(viewModel.result.done, 100);
      expect(changed, 1, reason: 'the first batch did change products');

      await viewModel.apply();

      // The second call is sent again, then the last; the first is never resent.
      expect(repository.applyCalls.map((ids) => ids.length), [
        100,
        100,
        100,
        50,
      ]);
      expect(repository.applyCalls[2].first, 101);
      expect(viewModel.applyInterrupted, isFalse);
      expect(viewModel.result.done, 250);
    },
  );

  test(
    'empty-shelf products are left out unless the owner opts back in',
    () async {
      final repository = FakeTrackingRepository(changeRows(10, emptyEvery: 5));
      final viewModel = await previewed(repository);

      expect(viewModel.excludeEmptyShelf, isTrue);
      expect(viewModel.idsToApply, [1, 2, 3, 4, 6, 7, 8, 9]);
      expect(viewModel.skippedEmptyShelf, 2);

      viewModel.setExcludeEmptyShelf(false);
      expect(viewModel.idsToApply.length, 10);

      viewModel.setExcludeEmptyShelf(true);
      await viewModel.apply();
      expect(repository.applyCalls.single, [1, 2, 3, 4, 6, 7, 8, 9]);
    },
  );

  test('only products that change are ever sent', () async {
    final repository = FakeTrackingRepository([
      ...changeRows(2),
      const BulkTrackingRow(
        product: 90,
        name: 'مرفوض',
        outcome: BulkTrackingOutcome.blocked,
        message: 'سبب',
      ),
      const BulkTrackingRow(
        product: 91,
        name: 'كما هو',
        outcome: BulkTrackingOutcome.same,
      ),
    ]);
    final viewModel = await previewed(repository);
    await viewModel.apply();
    expect(repository.applyCalls.single, [1, 2]);
  });

  test(
    'a request that changes nothing cannot be previewed or applied',
    () async {
      final repository = FakeTrackingRepository(changeRows(3));
      final viewModel = BulkTrackingViewModel(catalogRepository: repository);
      addTearDown(viewModel.dispose);

      await viewModel.refreshPreview();
      expect(viewModel.preview, isNull);

      viewModel.setReminderMode(BulkReminderMode.set);
      expect(viewModel.isComplete, isFalse, reason: 'a date is still missing');
      viewModel.setReminderDate(DateTime(2027, 3, 31));
      expect(viewModel.isComplete, isTrue);
    },
  );

  test('changing the choices after a preview makes it stale', () async {
    final repository = FakeTrackingRepository(changeRows(3));
    final viewModel = await previewed(repository);
    expect(viewModel.isPreviewFresh, isTrue);
    viewModel.setTracking(BulkTrackingTarget.lots);
    expect(viewModel.isPreviewFresh, isFalse);
    expect(viewModel.canApply, isFalse);
  });
}
