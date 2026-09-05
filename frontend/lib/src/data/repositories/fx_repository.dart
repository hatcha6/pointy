import '../../core/result.dart';
import '../models/currency.dart';
import '../services/pos_api_service.dart';

/// Currencies, for rendering a foreign price at the till.
class FxRepository {
  FxRepository(this._service);

  final PosApiService _service;

  Future<Result<List<Currency>>> loadCurrencies() {
    return Result.guard(() => _service.fetchCurrencies());
  }
}
