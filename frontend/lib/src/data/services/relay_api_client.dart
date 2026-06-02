import '../models/relay_pairing.dart';
import 'api_session.dart';

class RelayApiClient {
  const RelayApiClient(this._session);

  final PosApiSession _session;

  Future<RelayPairing> requestPairing(RelayPairingRequest request) async {
    final response = await _session.post(
      'relay/pairing/',
      body: request.toJson(),
    );
    _session.ensureSuccess(response, 'Relay pairing failed with status');
    return RelayPairing.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
