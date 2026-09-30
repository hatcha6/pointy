import '../../core/result.dart';
import '../models/wallet.dart';
import '../services/pos_api_service.dart';

/// The Daftar wallet, wrapped in [Result] so view models branch without
/// try/catch. A backend refusal arrives as a [WalletException] error.
class WalletRepository {
  const WalletRepository(this._service);

  final PosApiService _service;

  Future<Result<WalletOverview>> loadWallet() =>
      Result.guard(() => _service.wallet.fetchWallet());

  Future<Result<WalletPage<WalletTopUp>>> loadTopUps({String? before}) =>
      Result.guard(() => _service.wallet.fetchTopUps(before: before));

  Future<Result<WalletPage<WalletEntry>>> loadEntries({String? before}) =>
      Result.guard(() => _service.wallet.fetchEntries(before: before));

  Future<Result<WalletTopUpStart>> startTopUp({
    required String amount,
    required String method,
    required String idempotencyKey,
    bool? recordAsExpense,
  }) => Result.guard(
    () => _service.wallet.startTopUp(
      amount: amount,
      method: method,
      idempotencyKey: idempotencyKey,
      recordAsExpense: recordAsExpense,
    ),
  );

  Future<Result<WalletTopUp>> loadTopUp(String id) =>
      Result.guard(() => _service.wallet.fetchTopUp(id));

  Future<Result<WalletSettings>> updateSettings({
    required bool recordTopUpsAsExpenses,
  }) => Result.guard(
    () => _service.wallet.updateSettings(
      recordTopUpsAsExpenses: recordTopUpsAsExpenses,
    ),
  );
}
