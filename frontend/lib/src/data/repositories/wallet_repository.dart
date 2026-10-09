import '../../core/result.dart';
import '../models/wallet.dart';
import '../services/pos_api_service.dart';
import '../services/wallet_api_client.dart';

export '../services/wallet_api_client.dart' show WalletBankTransferRequest;

/// The Daftar wallet, wrapped in [Result] so view models branch without
/// try/catch. A backend refusal arrives as a [WalletException] error.
class WalletRepository {
  const WalletRepository(this._service);

  final PosApiService _service;

  Future<Result<WalletOverview>> loadWallet() =>
      Result.guard(() => _service.wallet.fetchWallet());

  Future<Result<WalletPage<WalletTopUp>>> loadTopUps({String? before}) =>
      Result.guard(() => _service.wallet.fetchTopUps(before: before));

  Future<Result<WalletPage<WalletEntry>>> loadEntries({
    String? before,
    WalletAccount account = WalletAccount.main,
  }) => Result.guard(
    () => _service.wallet.fetchEntries(before: before, account: account),
  );

  Future<Result<WalletSmsAllocation>> allocateToSms({
    required String amount,
    required String idempotencyKey,
  }) => Result.guard(
    () => _service.wallet.allocateToSms(
      amount: amount,
      idempotencyKey: idempotencyKey,
    ),
  );

  Future<Result<WalletVoucherAllocation>> allocateToVouchers({
    required String amount,
    required String idempotencyKey,
  }) => Result.guard(
    () => _service.wallet.allocateToVouchers(
      amount: amount,
      idempotencyKey: idempotencyKey,
    ),
  );

  Future<Result<WalletPlanPurchase>> purchasePlan({
    required String plan,
    required int periods,
    required String idempotencyKey,
  }) => Result.guard(
    () => _service.wallet.purchasePlan(
      plan: plan,
      periods: periods,
      idempotencyKey: idempotencyKey,
    ),
  );

  Future<Result<WalletTopUpStart>> startTopUp({
    required String amount,
    required String method,
    required String idempotencyKey,
    bool? recordAsExpense,
    String userIdentifier = '',
    String birthYear = '',
  }) => Result.guard(
    () => _service.wallet.startTopUp(
      amount: amount,
      method: method,
      idempotencyKey: idempotencyKey,
      recordAsExpense: recordAsExpense,
      userIdentifier: userIdentifier,
      birthYear: birthYear,
    ),
  );

  Future<Result<WalletTopUpStart>> startBankTransfer(
    WalletBankTransferRequest request, {
    void Function(int sent, int total)? onProgress,
  }) => Result.guard(
    () => _service.wallet.startBankTransfer(request, onProgress: onProgress),
  );

  Future<Result<WalletTopUp>> loadTopUp(String id) =>
      Result.guard(() => _service.wallet.fetchTopUp(id));

  Future<Result<WalletTopUpConfirmation>> confirmTopUp({
    required String id,
    required String otp,
  }) => Result.guard(() => _service.wallet.confirmTopUp(id: id, otp: otp));

  Future<Result<WalletTopUp>> cancelTopUp(String id) =>
      Result.guard(() => _service.wallet.cancelTopUp(id));

  Future<Result<WalletSettings>> updateSettings({
    required bool recordTopUpsAsExpenses,
  }) => Result.guard(
    () => _service.wallet.updateSettings(
      recordTopUpsAsExpenses: recordTopUpsAsExpenses,
    ),
  );
}
