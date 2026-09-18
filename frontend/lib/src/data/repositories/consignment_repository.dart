import '../../core/result.dart';
import '../models/consignment.dart';
import '../models/stock_unit.dart';
import '../services/pos_api_service.dart';

/// الأمانات, for the screens that work them.
///
/// Read-heavy by design: the payable, the position and the custody exposure are
/// all derived server-side from the units' own sales and their own payout rows,
/// so there is nothing here to cache and nothing that can drift.
class ConsignmentRepository {
  const ConsignmentRepository(this._service);

  final PosApiService _service;

  Future<Result<ConsignmentPayablePage>> loadPayables({int? consignorId}) {
    return Result.guard(
      () => _service.fetchConsignmentPayables(consignorId: consignorId),
    );
  }

  Future<Result<ConsignmentPosition>> loadPosition({
    DateTime? start,
    DateTime? end,
  }) {
    return Result.guard(
      () => _service.fetchConsignmentPosition(start: start, end: end),
    );
  }

  Future<Result<ConsignorPayout>> disburse({
    required int unitId,
    List<int> alsoUnitIds = const [],
    String method = 'cash',
    String reference = '',
  }) {
    return Result.guard(
      () => _service.disburseConsignmentPayout(
        unitId: unitId,
        alsoUnitIds: alsoUnitIds,
        method: method,
        reference: reference,
      ),
    );
  }

  Future<Result<bool>> resendSaleSms(int unitId) {
    return Result.guard(() => _service.resendConsignorSms(unitId));
  }

  Future<Result<StockUnit>> returnToConsignor(int unitId, {String note = ''}) {
    return Result.guard(
      () => _service.returnUnitToConsignor(unitId, note: note),
    );
  }

  Future<Result<List<ConsignmentAgreement>>> loadAgreements({
    int? consignorId,
    bool openOnly = false,
  }) {
    return Result.guard(
      () => _service.fetchConsignmentAgreements(
        consignorId: consignorId,
        openOnly: openOnly,
      ),
    );
  }

  /// Write the voucher and take the goods in, in that order and one act.
  Future<Result<ConsignmentAgreement>> takeIn({
    required int consignorId,
    required String payoutMode,
    double? payoutRate,
    double? commissionPct,
    double? reservePrice,
    required String liabilityPolicy,
    DateTime? expiresOn,
    String notes = '',
    required List<ConsignmentIntakeItem> items,
  }) {
    return Result.guard(() async {
      final agreement = await _service.createConsignmentAgreement({
        'consignor': consignorId,
        'payout_mode': payoutMode,
        'payout_rate': ?payoutRate,
        'commission_pct': ?commissionPct,
        'reserve_price': ?reservePrice,
        'liability_policy': liabilityPolicy,
        if (expiresOn != null)
          'expires_on': expiresOn.toIso8601String().substring(0, 10),
        if (notes.isNotEmpty) 'notes': notes,
      });
      return _service.submitConsignmentAgreement(agreement.id, items: items);
    });
  }
}
