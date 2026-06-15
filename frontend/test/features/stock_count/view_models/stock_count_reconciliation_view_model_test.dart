import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/stock_count.dart';
import 'package:pointy_frontend/src/data/models/stock_count_line.dart';
import 'package:pointy_frontend/src/data/repositories/stock_count_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/stock_count/view_models/stock_count_reconciliation_view_model.dart';

StockCount _session(StockCountStatus status) {
  return StockCount(
    id: 7,
    countNumber: 'SC-7',
    status: status,
    scope: StockCountScope.full,
    expectedLineCount: 5,
    countedLineCount: 5,
    varianceLineCount: 2,
  );
}

StockCountLine _line({required int id}) {
  return StockCountLine(
    id: id,
    stockCountId: 7,
    variantId: id,
    countedQuantity: 3,
    expectedQuantity: 5,
    variance: -2,
    needsReview: true,
    applied: false,
    staleAtApply: false,
  );
}

void main() {
  test('loads the differing lines', () async {
    final repo = _FakeStockCountRepository()
      ..lines = [_line(id: 1), _line(id: 2)];
    final vm = StockCountReconciliationViewModel(
      repo,
      session: _session(StockCountStatus.inProgress),
    );
    addTearDown(vm.dispose);

    await vm.load();

    expect(vm.lines.length, 2);
  });

  test('apply succeeds and reuses one idempotency key across calls', () async {
    final repo = _FakeStockCountRepository()..lines = [_line(id: 1)];
    final vm = StockCountReconciliationViewModel(
      repo,
      session: _session(StockCountStatus.inProgress),
    );
    addTearDown(vm.dispose);

    final applied = await vm.apply();
    expect(applied, isNotNull);
    expect(applied!.status, StockCountStatus.applied);

    // A second apply (e.g. a retry) must not mint a new key.
    await vm.apply();
    expect(repo.appliedKeys.length, 2);
    expect(repo.appliedKeys.toSet().length, 1);
  });

  test('a failed apply reports an apply error', () async {
    final repo = _FakeStockCountRepository()..failApply = true;
    final vm = StockCountReconciliationViewModel(
      repo,
      session: _session(StockCountStatus.inProgress),
    );
    addTearDown(vm.dispose);

    final applied = await vm.apply();
    expect(applied, isNull);
    expect(vm.applyError, isTrue);
  });
}

class _FakeStockCountRepository extends StockCountRepository {
  _FakeStockCountRepository() : super(PosApiService());

  List<StockCountLine> lines = const [];
  final List<String> appliedKeys = [];
  bool failApply = false;

  @override
  Future<Result<List<StockCountLine>>> loadReconciliation(int countId) async {
    return Ok(lines);
  }

  @override
  Future<Result<StockCount>> applyCount(
    int countId, {
    required String idempotencyKey,
  }) async {
    appliedKeys.add(idempotencyKey);
    if (failApply) {
      return Error(Exception('apply failed'));
    }
    return Ok(_session(StockCountStatus.applied));
  }
}
