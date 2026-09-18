import '../../core/result.dart';
import '../models/stock_batch.dart';
import '../models/stock_unit.dart';
import '../models/tracked_scan.dart';
import '../services/pos_api_service.dart';

/// Identified stock, for the screens that read it.
///
/// Thin on purpose. Almost everything that *happens* to a unit or a lot happens
/// because a document moved stock — a receipt, a sale, a transfer — so what is
/// left here is what a person legitimately does without moving anything: look
/// one up, price it, give it the identifier it has been owing, and stop a lot
/// from being sold.
class TrackedStockRepository {
  const TrackedStockRepository(this._service);

  final PosApiService _service;

  /// A scan the till's own catalog could not answer.
  ///
  /// Returns a [TrackedScan] whose `found` is false rather than an error when
  /// the code is simply not identified stock: a cashier scanning an unknown
  /// barcode should see "unknown item", not a network failure.
  Future<Result<TrackedScan>> resolveScan(
    String code, {
    bool activeOnly = true,
  }) {
    return Result.guard(
      () => _service.resolveTrackedScan(code, activeOnly: activeOnly),
    );
  }

  Future<Result<StockUnitPage>> loadUnits({
    int? variantId,
    int? productId,
    int? warehouseId,
    String status = '',
    String code = '',
    bool? isIdentified,
    bool? inStock,
    bool forSale = false,
    int page = 1,
  }) {
    return Result.guard(
      () => _service.fetchStockUnits(
        variantId: variantId,
        productId: productId,
        warehouseId: warehouseId,
        status: status,
        code: code,
        isIdentified: isIdentified,
        inStock: inStock,
        forSale: forSale,
        page: page,
      ),
    );
  }

  /// The units a till may actually ring up for this variant, oldest first.
  ///
  /// Oldest first because that is what a used-goods trader wants sold: stock
  /// ages, and an unsold handset loses value every week.
  Future<Result<StockUnitPage>> loadSellableUnits({required int variantId}) {
    // ``forSale`` rather than a warehouse id, because the till does not know
    // its own warehouse — the register profile does, and the backend already
    // resolves it for every checkout. Asking the client to guess would be
    // asking it to offer goods from another branch.
    return loadUnits(variantId: variantId, forSale: true);
  }

  Future<Result<StockUnit>> loadUnit(int unitId) {
    return Result.guard(() => _service.fetchStockUnit(unitId));
  }

  Future<Result<List<StockAllocationEntry>>> loadUnitHistory(int unitId) {
    return Result.guard(() => _service.fetchStockUnitHistory(unitId));
  }

  Future<Result<StockUnitLookup>> lookupUnit(String code) {
    return Result.guard(() => _service.lookupStockUnit(code));
  }

  Future<Result<StockUnitSummary>> loadUnitSummary({int? warehouseId}) {
    return Result.guard(
      () => _service.fetchStockUnitSummary(warehouseId: warehouseId),
    );
  }

  Future<Result<StockUnit>> identifyUnit(
    int unitId, {
    required String code,
    String secondaryCode = '',
    String identifierKind = '',
  }) {
    return Result.guard(
      () => _service.identifyStockUnit(
        unitId,
        code: code,
        secondaryCode: secondaryCode,
        identifierKind: identifierKind,
      ),
    );
  }

  Future<Result<StockUnit>> repriceUnit(int unitId, double? listPrice) {
    return Result.guard(
      () => _service.updateStockUnit(unitId, {'list_price': listPrice}),
    );
  }

  Future<Result<StockUnit>> updateUnitNotes(int unitId, String notes) {
    return Result.guard(
      () => _service.updateStockUnit(unitId, {'notes': notes}),
    );
  }

  /// Take an article off the shelf because it is gone, or broken.
  ///
  /// A movement, not a status flip: the bin drops by one and the ledger records
  /// why, which is the difference between a unit nobody can find and a quantity
  /// that still counts it.
  Future<Result<StockUnit>> writeOffUnit(int unitId, {required String reason}) {
    return Result.guard(() => _service.writeOffStockUnit(unitId, reason: reason));
  }

  Future<Result<bool>> resendConsignorSms(int unitId) {
    return Result.guard(() => _service.resendConsignorSms(unitId));
  }

  Future<Result<StockBatchPage>> loadBatches({
    int? variantId,
    int? productId,
    int? warehouseId,
    String status = '',
    bool? isExpired,
    bool forSale = false,
    int page = 1,
  }) {
    return Result.guard(
      () => _service.fetchStockBatches(
        variantId: variantId,
        productId: productId,
        warehouseId: warehouseId,
        status: status,
        isExpired: isExpired,
        forSale: forSale,
        page: page,
      ),
    );
  }

  /// The lots a till may sell from for this variant **in this warehouse**.
  ///
  /// Stock of the same lot sitting in another branch is deliberately absent:
  /// it is not on this shelf, and offering it would be offering something the
  /// cashier cannot hand over.
  Future<Result<StockBatchPage>> loadSellableBatches({required int variantId}) {
    return loadBatches(variantId: variantId, forSale: true);
  }

  Future<Result<StockBatch>> loadBatch(int batchId) {
    return Result.guard(() => _service.fetchStockBatch(batchId));
  }

  Future<Result<List<StockAllocationEntry>>> loadBatchHistory(int batchId) {
    return Result.guard(() => _service.fetchStockBatchHistory(batchId));
  }

  Future<Result<StockBatch>> setQuarantine(
    int batchId, {
    required bool locked,
  }) {
    return Result.guard(
      () => _service.setStockBatchQuarantine(batchId, locked: locked),
    );
  }

  Future<Result<StockBatchPage>> loadExpiryWatchlist({int days = 30}) {
    return Result.guard(() => _service.fetchExpiryWatchlist(days: days));
  }
}
