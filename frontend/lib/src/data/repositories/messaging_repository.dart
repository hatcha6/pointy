import '../../core/result.dart';
import '../models/messaging_gateway.dart';
import '../services/pos_api_service.dart';

/// Access to the shop's messaging gateways (the SMS Gate phone config) and the
/// Test-send action. Every call is wrapped in [Result] so the view model can
/// branch without try/catch. Powers the SMS device settings page in Shop Settings.
class MessagingRepository {
  const MessagingRepository(this._service);

  final PosApiService _service;

  Future<Result<List<MessagingGateway>>> loadGateways() {
    return Result.guard(_service.fetchMessagingGateways);
  }

  Future<Result<MessagingGateway>> createGateway(MessagingGatewayDraft draft) {
    return Result.guard(() => _service.createMessagingGateway(draft));
  }

  Future<Result<MessagingGateway>> updateGateway(
    int id,
    MessagingGatewayDraft draft,
  ) {
    return Result.guard(() => _service.updateMessagingGateway(id, draft));
  }

  Future<Result<void>> deleteGateway(int id) {
    return Result.guard(() => _service.deleteMessagingGateway(id));
  }

  Future<Result<MessagingSendResult>> testSend({
    required int id,
    required String to,
    String? body,
  }) {
    return Result.guard(
      () => _service.testSendMessagingGateway(id: id, to: to, body: body),
    );
  }

  Future<Result<GatewayActivation>> activate(int id) {
    return Result.guard(() => _service.activateMessagingGateway(id));
  }
}
