import '../../core/result.dart';
import '../models/business_alert.dart';
import '../services/pos_api_service.dart';

class BusinessAlertLoadResult {
  const BusinessAlertLoadResult({required this.digest});

  final BusinessAlertDigest digest;
}

class BusinessAlertRepository {
  BusinessAlertRepository(this._service);

  final PosApiService _service;

  Future<Result<BusinessAlertLoadResult>> loadAlerts() {
    return Result.guard(
      () async => BusinessAlertLoadResult(
        digest: await _service.fetchBusinessNotifications(includeHidden: true),
      ),
    );
  }

  Future<Result<BusinessAlert>> dismissAlert(String id) {
    return Result.guard(() => _service.dismissBusinessNotification(id));
  }

  Future<Result<BusinessAlert>> snoozeAlert(String id, {required int hours}) {
    return Result.guard(
      () => _service.snoozeBusinessNotification(id, hours: hours),
    );
  }

  Future<Result<void>> dismissActiveAlerts() {
    return Result.guard(_service.dismissAllBusinessNotifications);
  }

  Future<Result<void>> restoreHiddenAlerts() {
    return Result.guard(_service.restoreHiddenBusinessNotifications);
  }
}
