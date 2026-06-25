import '../models/relay_installation_status.dart';
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

  /// Current relay installation + subscription snapshot. Pass [sync] to have the
  /// backend pull the latest entitlement state from the relay control server
  /// first (which may fail with a gateway error if the relay is unreachable).
  Future<RelayInstallationStatus> fetchInstallationStatus({
    bool sync = false,
  }) async {
    final response = await _session.get(
      'relay/installation/',
      query: sync ? const {'sync': '1'} : null,
    );
    _session.ensureSuccess(
      response,
      'Relay installation status failed with status',
    );
    return RelayInstallationStatus.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
