import '../../core/result.dart';
import '../models/consignment.dart';
import '../models/missing_lot.dart';
import '../models/stock_batch.dart';
import '../models/stock_unit.dart';
import '../models/tracked_scan.dart';
import '../models/unit_attribute.dart';
import '../models/unit_checklist_kind.dart';
import '../models/unit_photo.dart';
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
    int? batchId,
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
        batchId: batchId,
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

  /// The fields a kind of article records, for its attribute form.
  Future<Result<List<UnitAttributeDefinition>>> loadAttributeDefinitions(
    int assetTypeId,
  ) {
    return Result.guard(
      () => _service.fetchUnitAttributeDefinitions(assetTypeId),
    );
  }

  // -- condition checklists («قوائم فحص الأجهزة») ---------------------------

  /// Every active kind of device, with how many facts its checklist records.
  Future<Result<List<UnitChecklistKind>>> loadChecklistKinds() {
    return Result.guard(_service.fetchUnitChecklistKinds);
  }

  /// Adds a field (no [UnitAttributeDefinition.id]) or edits one.
  Future<Result<UnitAttributeDefinition>> saveAttributeDefinition(
    UnitAttributeDefinition definition,
  ) {
    return Result.guard(
      () => definition.id == 0
          ? _service.createUnitAttributeDefinition(definition)
          : _service.updateUnitAttributeDefinition(definition),
    );
  }

  /// Values units recorded under it stay on them; they just stop showing.
  Future<Result<void>> deleteAttributeDefinition(int definitionId) {
    return Result.guard(
      () => _service.deleteUnitAttributeDefinition(definitionId),
    );
  }

  Future<Result<List<UnitAttributeDefinition>>> reorderAttributeDefinitions(
    int assetTypeId,
    List<int> definitionIds,
  ) {
    return Result.guard(
      () =>
          _service.reorderUnitAttributeDefinitions(assetTypeId, definitionIds),
    );
  }

  /// Replace an article's facts; the server checks them against its kind.
  Future<Result<StockUnit>> saveUnitAttributes(
    int unitId,
    Map<String, Object?> attributes,
  ) {
    return Result.guard(
      () => _service.saveStockUnitAttributes(unitId, attributes),
    );
  }

  /// The article's own warranty end date, or null for the product's days.
  Future<Result<StockUnit>> setUnitWarrantyOverride(
    int unitId,
    DateTime? expiresOn,
  ) {
    return Result.guard(
      () => _service.setStockUnitWarrantyOverride(unitId, expiresOn),
    );
  }

  Future<Result<List<UnitPhoto>>> loadUnitPhotos(int unitId) {
    return Result.guard(() => _service.fetchStockUnitPhotos(unitId));
  }

  Future<Result<UnitPhoto>> uploadUnitPhoto(
    int unitId,
    UnitPhotoUpload upload, {
    void Function(int sent, int total)? onProgress,
  }) {
    return Result.guard(
      () =>
          _service.uploadStockUnitPhoto(unitId, upload, onProgress: onProgress),
    );
  }

  Future<Result<void>> deleteUnitPhoto(int unitId, int photoId) {
    return Result.guard(() => _service.deleteStockUnitPhoto(unitId, photoId));
  }

  Future<Result<UnitPhoto>> setUnitCoverPhoto(int unitId, int photoId) {
    return Result.guard(() => _service.setStockUnitCoverPhoto(unitId, photoId));
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
    return Result.guard(
      () => _service.writeOffStockUnit(unitId, reason: reason),
    );
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
    String reason = '',
  }) {
    return Result.guard(
      () => _service.setStockBatchQuarantine(
        batchId,
        locked: locked,
        reason: reason,
      ),
    );
  }

  Future<Result<(StockBatchPage, Map<int, ExpiryMarkdownSuggestion>)>>
  loadExpiryWatchlist({int days = 30}) {
    return Result.guard(() => _service.fetchExpiryWatchlist(days: days));
  }

  // -- recall (§6.8.1) -----------------------------------------------------

  Future<Result<BatchRecallReport>> loadRecallReport(int batchId) {
    return Result.guard(() => _service.fetchRecallReport(batchId));
  }

  /// One tap, one message each, to everybody the shop can reach.
  Future<Result<RecallNotifyResult>> notifyAffectedCustomers(int batchId) {
    return Result.guard(() => _service.notifyAffectedCustomers(batchId));
  }

  // -- custody (§6.2.2) ----------------------------------------------------

  Future<Result<ConsignmentIncident>> reportIncident(
    int unitId,
    ConsignmentIncidentDraft draft,
  ) {
    return Result.guard(
      () => _service.reportConsignmentIncident(unitId, draft),
    );
  }

  Future<Result<List<ConsignmentIncident>>> loadUnitIncidents(int unitId) {
    return Result.guard(() => _service.fetchUnitIncidents(unitId));
  }

  Future<Result<List<ConsignmentIncident>>> loadIncidents({
    bool openOnly = false,
    int page = 1,
  }) {
    return Result.guard(
      () => _service.fetchConsignmentIncidents(openOnly: openOnly, page: page),
    );
  }

  Future<Result<ConsignmentIncident>> assessIncident(
    int incidentId, {
    required String responsibility,
    double? assessedValue,
    String note = '',
  }) {
    return Result.guard(
      () => _service.assessConsignmentIncident(
        incidentId,
        responsibility: responsibility,
        assessedValue: assessedValue,
        note: note,
      ),
    );
  }

  Future<Result<ConsignmentIncident>> settleIncident(
    int incidentId, {
    required String resolution,
    String method = 'cash',
    int? replacementUnitId,
    String reference = '',
    String notes = '',
  }) {
    return Result.guard(
      () => _service.settleConsignmentIncident(
        incidentId,
        resolution: resolution,
        method: method,
        replacementUnitId: replacementUnitId,
        reference: reference,
        notes: notes,
      ),
    );
  }

  Future<Result<UnclaimedPayoutAging>> loadUnclaimedPayouts() {
    return Result.guard(() => _service.fetchUnclaimedPayouts());
  }

  // -- opening identification (§6.10) --------------------------------------

  Future<Result<List<OpeningIdentificationRow>>> loadOpeningWorklist() {
    return Result.guard(() => _service.fetchOpeningWorklist());
  }

  Future<Result<int>> identifyOpeningStock({
    required int variantId,
    List<Map<String, Object?>> units = const [],
    List<Map<String, Object?>> batches = const [],
    bool captureLater = false,
  }) {
    return Result.guard(
      () => _service.identifyOpeningStock(
        variantId: variantId,
        units: units,
        batches: batches,
        captureLater: captureLater,
      ),
    );
  }

  // -- the lot worklist (§4.2) ---------------------------------------------

  /// Variants whose units on the shelf are still owed a lot, largest first.
  Future<Result<List<MissingLotGroup>>> loadMissingLotGroups({int? productId}) {
    return Result.guard(
      () => _service.fetchMissingLotGroups(productId: productId),
    );
  }

  /// One variant's lot-less units, a page at a time; [code] finds a scanned
  /// one past the first page.
  Future<Result<StockUnitPage>> loadMissingLotUnits({
    required int variantId,
    String code = '',
    int page = 1,
  }) {
    return Result.guard(
      () => _service.fetchMissingLotUnits(
        variantId: variantId,
        code: code,
        page: page,
      ),
    );
  }

  /// Put [unitIds] into one lot. Nothing moves: the lot's balance takes them
  /// and the units remember when.
  Future<Result<LotAssignment>> assignLot({
    required int variantId,
    required List<int> unitIds,
    required LotChoice lot,
  }) {
    return Result.guard(
      () =>
          _service.assignLot(variantId: variantId, unitIds: unitIds, lot: lot),
    );
  }

  /// `allocations ∪ events`, in time order (§6.9).
  Future<Result<List<StockUnitTimelineEntry>>> loadUnitTimeline(int unitId) {
    return Result.guard(() => _service.fetchStockUnitTimeline(unitId));
  }
}
