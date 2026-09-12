import '../../core/result.dart';
import '../models/exchange_rate.dart';
import '../services/pos_api_service.dart';

/// Exchange rates and foreign-currency repricing.
class FxRepository {
  FxRepository(this._service);

  final PosApiService _service;

  Future<Result<CurrentRates>> loadCurrentRates() {
    return Result.guard(() => _service.fetchCurrentRates());
  }

  Future<Result<List<Currency>>> loadCurrencies() {
    return Result.guard(() => _service.fetchCurrencies());
  }

  Future<Result<List<ExchangeRate>>> loadRateHistory({
    String? fromCode,
    int pageSize = 100,
  }) {
    return Result.guard(
      () => _service.fetchRateHistory(fromCode: fromCode, pageSize: pageSize),
    );
  }

  Future<Result<ExchangeRate>> recordManualRate(ManualRateDraft draft) {
    return Result.guard(() => _service.recordManualRate(draft));
  }

  Future<Result<Map<String, Object?>>> syncNow() {
    return Result.guard(() => _service.syncExchangeRates());
  }

  Future<Result<RepricePreview>> loadRepricePreview() {
    return Result.guard(() => _service.fetchRepricePreview());
  }

  Future<Result<int>> applyReprice(
    List<PriceProposal> approved, {
    DateTime? resolvedAt,
  }) {
    return Result.guard(
      () => _service.applyReprice(approved, resolvedAt: resolvedAt),
    );
  }
}
