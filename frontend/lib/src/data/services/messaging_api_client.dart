import '../models/messaging_gateway.dart';
import '../models/messaging_status.dart';
import 'api_session.dart';

/// REST access to the SMS service (apps.messaging): the status read behind
/// the settings page, `PATCH /api/messaging/gateways/{id}/` for the shop's
/// dials, and the per-gateway `POST .../test_send/`.
///
/// Failures throw [PosApiException] rather than a bare `Exception` so the page
/// can show the backend's own reason — a refused entitlement, a cap, a bad
/// number — instead of a generic "couldn't save".
class MessagingApiClient {
  const MessagingApiClient(this._session);

  final PosApiSession _session;

  Future<MessagingServiceStatus> fetchStatus() async {
    final response = await _session.get('messaging/status/');
    _session.throwApiException(
      response,
      'Messaging status request failed with status',
    );
    return MessagingServiceStatus.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<MessagingGateway> updateGateway(
    int id,
    MessagingGatewayUpdate update,
  ) async {
    final response = await _session.patch(
      'messaging/gateways/$id/',
      body: update.toJson(),
    );
    _session.throwApiException(response, 'Gateway update failed with status');
    return MessagingGateway.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Turns one automatic text on or off. The server keeps every other switch
  /// as it was.
  Future<MessagingGateway> setAutoMessage(
    int id, {
    required String kind,
    required bool enabled,
  }) async {
    final response = await _session.patch(
      'messaging/gateways/$id/',
      body: {
        'auto_messages': {kind: enabled},
      },
    );
    _session.throwApiException(response, 'Gateway update failed with status');
    return MessagingGateway.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Sends the approved test template to [to]. There is no free-text body any
  /// more: every SMS is a template the provider has approved.
  Future<MessagingSendResult> testSend({
    required int id,
    required String to,
  }) async {
    final response = await _session.post(
      'messaging/gateways/$id/test_send/',
      body: {'to': to},
    );
    _session.throwApiException(response, 'Test send failed with status');
    return MessagingSendResult.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
