import '../../core/result.dart';
import '../models/money_position.dart';
import '../services/pos_api_service.dart';

/// Read and write access to the money position (الخزينة): balances, the events
/// behind them, physical counts, and moves between the shop's own accounts.
class TreasuryRepository {
  const TreasuryRepository(this._service);

  final PosApiService _service;

  Future<Result<MoneyPosition>> loadPosition({DateTime? asOf}) {
    return Result.guard(() => _service.fetchMoneyPosition(asOf: asOf));
  }

  Future<Result<MoneyMovementPage>> loadAccountMovements(
    int accountId, {
    DateTime? start,
    DateTime? end,
  }) {
    return Result.guard(
      () => _service.fetchMoneyAccountMovements(
        accountId,
        start: start,
        end: end,
      ),
    );
  }

  Future<Result<MoneyCount>> recordCount({
    required int accountId,
    required double countedAmount,
    String note = '',
    String? idempotencyKey,
  }) {
    return Result.guard(
      () => _service.recordMoneyCount(
        accountId: accountId,
        countedAmount: countedAmount,
        note: note,
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  Future<Result<void>> recordTransfer(
    MoneyTransferDraft draft, {
    String? idempotencyKey,
  }) {
    return Result.guard(
      () => _service.recordMoneyTransfer(draft, idempotencyKey: idempotencyKey),
    );
  }

  Future<Result<List<MoneyAccount>>> loadAccounts() {
    return Result.guard(() => _service.fetchMoneyAccounts());
  }

  Future<Result<MoneyAccount>> createAccount(MoneyAccount account) {
    return Result.guard(() => _service.createMoneyAccount(account));
  }

  Future<Result<MoneyAccount>> updateAccount(
    int accountId,
    Map<String, Object?> changes,
  ) {
    return Result.guard(() => _service.updateMoneyAccount(accountId, changes));
  }
}
