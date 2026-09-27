import '../../core/result.dart';
import '../models/messaging_gateway.dart';
import '../models/messaging_status.dart';
import '../services/pos_api_service.dart';

/// Access to the shop's SMS service: its status (entitlement, usage, the texts
/// sent), the shop's own dials on its gateway, and the test send. Every call is
/// wrapped in [Result] so the view model can branch without try/catch. Powers
/// the SMS settings page in Shop Settings.
class MessagingRepository {
  const MessagingRepository(this._service);

  final PosApiService _service;

  Future<Result<MessagingServiceStatus>> loadStatus() {
    return Result.guard(_service.fetchMessagingStatus);
  }

  Future<Result<MessagingGateway>> updateGateway(
    int id,
    MessagingGatewayUpdate update,
  ) {
    return Result.guard(() => _service.updateMessagingGateway(id, update));
  }

  Future<Result<MessagingSendResult>> testSend({
    required int id,
    required String to,
  }) {
    return Result.guard(
      () => _service.testSendMessagingGateway(id: id, to: to),
    );
  }
}
