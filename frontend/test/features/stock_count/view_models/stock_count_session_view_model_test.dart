import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/stock_count.dart';
import 'package:pointy_frontend/src/data/models/stock_count_draft.dart';
import 'package:pointy_frontend/src/data/models/stock_count_line.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/stock_count_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/stock_count/view_models/stock_count_session_view_model.dart';

StockCount _session({List<StockCountLine> lines = const []}) {
  return StockCount(
    id: 1,
    countNumber: 'SC-1',
    status: StockCountStatus.inProgress,
    scope: StockCountScope.full,
    expectedLineCount: 10,
    countedLineCount: lines.length,
    varianceLineCount: 0,
    lines: lines,
  );
}

ProductVariant _variant({int id = 5}) {
  return ProductVariant(id: id, productId: 1, sku: 'SKU-$id', unitPrice: 1);
}

void main() {
  test(
    'scan then count records a line and advances to the next item',
    () async {
      final repo = _FakeStockCountRepository()..nextExpected = 0;
      final vm = StockCountSessionViewModel(
        repo,
        _FakeCatalogRepository(_variant()),
        session: _session(),
      );
      addTearDown(vm.dispose);

      await vm.onBarcodeScanned('1234567');
      expect(vm.currentVariant, isNotNull);

      vm.appendDigit('8');
      expect(vm.input, '8');
      expect(vm.canSubmit, isTrue);

      await vm.submit();

      expect(repo.drafts.single.countedQuantity, 8);
      expect(repo.drafts.single.mode, StockCountEntryMode.replace);
      expect(vm.countedCount, 1);
      expect(vm.currentVariant, isNull, reason: 'advances to the next item');
      // Blind: a within-threshold entry never surfaces the expected quantity.
      expect(vm.pendingVariance, isNull);
    },
  );

  test('an un-submitted keypad entry is restored on re-entry', () async {
    final storage = MemoryScopedJsonStorage();
    final variant = _variant(id: 42);
    final first = StockCountSessionViewModel(
      _FakeStockCountRepository(),
      _FakeCatalogRepository(variant),
      session: _session(),
      entryStorage: storage,
    );
    addTearDown(first.dispose);
    // Let the (empty) restore complete so persistence is armed.
    await Future<void>.delayed(const Duration(milliseconds: 10));

    first.selectVariant(variant);
    first.appendDigit('7');
    expect(first.input, '7');

    // Let the debounced entry save flush to storage.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final second = StockCountSessionViewModel(
      _FakeStockCountRepository(),
      _FakeCatalogRepository(variant),
      session: _session(),
      entryStorage: storage,
    );
    addTearDown(second.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(second.currentVariant?.id, 42);
    expect(second.input, '7');
  });

  test('a flagged entry surfaces the variance prompt once', () async {
    final repo = _FakeStockCountRepository()
      ..nextExpected = 50
      ..nextNeedsReview = true;
    final variant = _variant();
    final vm = StockCountSessionViewModel(
      repo,
      _FakeCatalogRepository(variant),
      session: _session(),
    );
    addTearDown(vm.dispose);

    vm.selectVariant(variant);
    vm.appendDigit('3');
    await vm.submit();

    expect(vm.pendingVariance, isNotNull);
    expect(vm.pendingVariance!.expected, 50);
    expect(vm.pendingVariance!.counted, 3);

    vm.recountVariance();
    expect(vm.pendingVariance, isNull);
    expect(vm.currentVariant?.id, variant.id, reason: 're-selected to recount');
  });

  test(
    're-counting an item prompts add/replace and forwards the mode',
    () async {
      final variant = _variant();
      final repo = _FakeStockCountRepository()..nextExpected = 12;
      final vm = StockCountSessionViewModel(
        repo,
        _FakeCatalogRepository(variant),
        session: _session(
          lines: [
            StockCountLine(
              id: 1,
              stockCountId: 1,
              variantId: variant.id,
              countedQuantity: 12,
              expectedQuantity: 12,
              variance: 0,
              needsReview: false,
              applied: false,
              staleAtApply: false,
            ),
          ],
        ),
      );
      addTearDown(vm.dispose);

      vm.selectVariant(variant);
      vm.appendDigit('3');
      await vm.submit();

      expect(
        repo.drafts,
        isEmpty,
        reason: 'not saved until the choice is made',
      );
      expect(vm.pendingReentry, isNotNull);
      expect(vm.pendingReentry!.existingQuantity, 12);
      expect(vm.pendingReentry!.enteredQuantity, 3);

      await vm.resolveReentry(StockCountEntryMode.add);
      expect(repo.drafts.single.mode, StockCountEntryMode.add);
      expect(repo.drafts.single.countedQuantity, 3);
    },
  );

  test('a failed save reports an action error', () async {
    final repo = _FakeStockCountRepository()..failNext = true;
    final variant = _variant();
    final vm = StockCountSessionViewModel(
      repo,
      _FakeCatalogRepository(variant),
      session: _session(),
    );
    addTearDown(vm.dispose);

    vm.selectVariant(variant);
    vm.appendDigit('4');
    await vm.submit();

    expect(vm.actionError, isTrue);
    expect(vm.countedCount, 0);
  });
}

class _FakeStockCountRepository extends StockCountRepository {
  _FakeStockCountRepository() : super(PosApiService());

  final List<StockCountLineDraft> drafts = [];
  double nextExpected = 0;
  bool nextNeedsReview = false;
  bool failNext = false;

  @override
  Future<Result<StockCountLine>> recordLine(
    int countId,
    StockCountLineDraft draft,
  ) async {
    if (failNext) {
      return Error(Exception('record failed'));
    }
    drafts.add(draft);
    return Ok(
      StockCountLine(
        id: drafts.length,
        stockCountId: countId,
        variantId: draft.variantId,
        countedQuantity: draft.countedQuantity,
        expectedQuantity: nextExpected,
        variance: draft.countedQuantity - nextExpected,
        needsReview: nextNeedsReview,
        applied: false,
        staleAtApply: false,
      ),
    );
  }
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository(this._variant) : super(PosApiService());

  final ProductVariant? _variant;

  @override
  Future<Result<ProductVariant?>> findProductVariantByBarcode(
    String barcode, {
    bool activeOnly = true,
  }) async {
    return Ok(_variant);
  }
}
