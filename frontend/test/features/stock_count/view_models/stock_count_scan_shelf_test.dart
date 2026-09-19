import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/stock_batch.dart';
import 'package:pointy_frontend/src/data/models/stock_count.dart';
import 'package:pointy_frontend/src/data/models/stock_count_draft.dart';
import 'package:pointy_frontend/src/data/models/stock_count_line.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/stock_count_repository.dart';
import 'package:pointy_frontend/src/data/repositories/tracked_stock_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/stock_count/view_models/stock_count_session_view_model.dart';

/// §6.6 from the counter's side: a shelf of handsets is scanned, not typed.

StockCount _session() {
  return const StockCount(
    id: 1,
    countNumber: 'SC-1',
    status: StockCountStatus.inProgress,
    scope: StockCountScope.full,
    expectedLineCount: 3,
    countedLineCount: 0,
    varianceLineCount: 0,
  );
}

ProductVariant _variant({int id = 5, TrackingMode mode = TrackingMode.serial}) {
  return ProductVariant(
    id: id,
    productId: 1,
    sku: 'SKU-$id',
    unitPrice: 1,
    trackingMode: mode,
  );
}

void main() {
  test('a serialized item is counted by scanning, never by typing', () async {
    final repository = _FakeRepository();
    final viewModel = StockCountSessionViewModel(
      repository,
      _FakeCatalog(_variant()),
      session: _session(),
    );
    addTearDown(viewModel.dispose);

    // The barcode on the box resolves to the product; from there the count is
    // the scan loop.
    await viewModel.onBarcodeScanned('BOX-BARCODE');

    expect(viewModel.countsByScan, isTrue);
    expect(viewModel.countsByLot, isFalse);
  });

  test('the same handset scanned twice is one handset', () async {
    final repository = _FakeRepository();
    final viewModel = StockCountSessionViewModel(
      repository,
      _FakeCatalog(null),
      session: _session(),
    );
    addTearDown(viewModel.dispose);

    await viewModel.recordIdentifier('358240051111110');
    await viewModel.recordIdentifier('358240051111110');

    expect(repository.scanned, hasLength(2), reason: 'both reach the server');
    expect(
      viewModel.scans,
      hasLength(1),
      reason: 'the second is the same article, and the count says so',
    );
    expect(viewModel.lastScan!.created, isFalse);
  });

  test('a code nothing recognises asks what it is', () async {
    final repository = _FakeRepository()..knownCodes = const {};
    final viewModel = StockCountSessionViewModel(
      repository,
      _FakeCatalog(null),
      session: _session(),
    );
    addTearDown(viewModel.dispose);

    await viewModel.recordIdentifier('STRANGER');

    expect(viewModel.unknownCode, 'STRANGER');

    await viewModel.attachUnknownScan(_variant(id: 9));

    expect(viewModel.unknownCode, isNull);
    expect(repository.scanned.last.variantId, 9);
  });

  test('a lot-tracked item cannot be counted until a lot is chosen', () async {
    final repository = _FakeRepository();
    final tracked = _FakeTrackedRepository();
    final viewModel = StockCountSessionViewModel(
      repository,
      _FakeCatalog(_variant(mode: TrackingMode.batch)),
      session: _session(),
      trackedStockRepository: tracked,
    );
    addTearDown(viewModel.dispose);

    await viewModel.onBarcodeScanned('BOX-BARCODE');
    await Future<void>.delayed(Duration.zero);

    expect(viewModel.countsByLot, isTrue);
    viewModel.appendDigit('8');
    // Two lots came back, so nothing is pre-selected and the count is blocked
    // until the counter says which shelf they are standing at.
    expect(viewModel.canSubmit, isFalse);

    viewModel.selectLot(tracked.lots.first.id);
    viewModel.appendDigit('8');

    expect(viewModel.canSubmit, isTrue);
    await viewModel.submit();
    expect(repository.drafts.single.batchId, tracked.lots.first.id);
  });
}

class _FakeRepository extends StockCountRepository {
  _FakeRepository() : super(PosApiService());

  final List<StockCountLineDraft> drafts = [];
  final List<({String code, int? variantId})> scanned = [];
  final Set<String> seen = {};
  Set<String> knownCodes = const {'358240051111110'};

  @override
  Future<Result<StockCountScanResult>> scan(
    int countId,
    String code, {
    int? variantId,
  }) async {
    scanned.add((code: code, variantId: variantId));
    final isNew = seen.add(code);
    return Ok(
      StockCountScanResult(
        id: scanned.length,
        code: code,
        created: isNew,
        known: knownCodes.contains(code),
        variantId: knownCodes.contains(code) ? 5 : variantId,
      ),
    );
  }

  @override
  Future<Result<StockCountLine>> recordLine(
    int countId,
    StockCountLineDraft draft,
  ) async {
    drafts.add(draft);
    return Ok(
      StockCountLine(
        id: drafts.length,
        stockCountId: countId,
        variantId: draft.variantId,
        countedQuantity: draft.countedQuantity,
        expectedQuantity: draft.countedQuantity,
        variance: 0,
        needsReview: false,
        applied: false,
        staleAtApply: false,
      ),
    );
  }
}

class _FakeCatalog extends CatalogRepository {
  _FakeCatalog(this._variant) : super(PosApiService());

  final ProductVariant? _variant;

  @override
  Future<Result<ProductVariant?>> findProductVariantByBarcode(
    String barcode, {
    bool activeOnly = true,
  }) async {
    return Ok(_variant);
  }
}

class _FakeTrackedRepository extends TrackedStockRepository {
  _FakeTrackedRepository() : super(PosApiService());

  final List<StockBatch> lots = const [
    StockBatch(id: 11, variantId: 5, code: 'L-A', displayCode: 'L-A'),
    StockBatch(id: 12, variantId: 5, code: 'L-B', displayCode: 'L-B'),
  ];

  @override
  Future<Result<StockBatchPage>> loadSellableBatches({
    required int variantId,
  }) async {
    return Ok(StockBatchPage(batches: lots));
  }
}
