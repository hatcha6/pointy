import '../models/messaging_gateway.dart';
import 'api_session.dart';

/// REST access to the messaging gateway endpoints (apps.messaging):
/// `GET/POST/PATCH/DELETE /api/messaging/gateways/` and the per-gateway
/// `POST .../test_send/` action. Mirrors [PrintingApiClient]'s shape.
class MessagingApiClient {
  const MessagingApiClient(this._session);

  final PosApiSession _session;

  Future<List<MessagingGateway>> fetchGateways() async {
    final response = await _session.get('messaging/gateways/');
    _session.ensureSuccess(
      response,
      'Messaging gateways request failed with status',
    );
    final decoded = _session.decodedBody(response);
    final items = decoded is Map<String, Object?>
        ? (decoded['results'] as List<Object?>? ?? const [])
        : (decoded as List<Object?>? ?? const []);
    return items
        .whereType<Map<String, Object?>>()
        .map(MessagingGateway.fromJson)
        .toList();
  }

  Future<MessagingGateway> createGateway(MessagingGatewayDraft draft) async {
    final response = await _session.post(
      'messaging/gateways/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(response, 'Gateway creation failed with status');
    return MessagingGateway.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<MessagingGateway> updateGateway(
    int id,
    MessagingGatewayDraft draft,
  ) async {
    final response = await _session.patch(
      'messaging/gateways/$id/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(response, 'Gateway update failed with status');
    return MessagingGateway.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteGateway(int id) async {
    final response = await _session.delete('messaging/gateways/$id/');
    _session.ensureSuccess(response, 'Gateway delete failed with status');
  }

  Future<MessagingSendResult> testSend({
    required int id,
    required String to,
    String? body,
  }) async {
    final response = await _session.post(
      'messaging/gateways/$id/test_send/',
      body: {'to': to, if (body != null && body.isNotEmpty) 'body': body},
    );
    _session.ensureSuccess(response, 'Test send failed with status');
    return MessagingSendResult.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<GatewayActivation> activate(int id) async {
    final response = await _session.post('messaging/gateways/$id/activate/');
    _session.ensureSuccess(response, 'Gateway activation failed with status');
    return GatewayActivation.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
