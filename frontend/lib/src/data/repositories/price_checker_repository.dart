import '../../core/result.dart';
import '../models/price_check_event.dart';
import '../models/price_checker_device.dart';
import '../services/pos_api_service.dart';

/// Read-oriented access to the price-checker fleet: list devices, trigger a
/// LAN scan, and read a device's recent scan events. All calls are wrapped in
/// [Result] so view models can branch on success/failure without try/catch.
class PriceCheckerRepository {
  const PriceCheckerRepository(this._service);

  final PosApiService _service;

  Future<Result<List<PriceCheckerDevice>>> loadDevices({int page = 1}) async {
    return Result.guard(() => _service.fetchPriceCheckerDevices(page: page));
  }

  Future<Result<PriceCheckerScanSummary>> runScan() async {
    return Result.guard(() => _service.runPriceCheckerScan());
  }

  Future<Result<List<PriceCheckEvent>>> loadEvents({
    int? deviceId,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchPriceCheckEvents(deviceId: deviceId, page: page),
    );
  }
}
