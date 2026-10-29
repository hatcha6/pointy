import '../models/relay_installation_status.dart';
import '../models/relay_pairing.dart';
import '../models/remote_sign_in_status.dart';
import 'api_session.dart';

class RelayApiClient {
  const RelayApiClient(this._session);

  final PosApiSession _session;

  Future<RelayPairing> requestPairing(RelayPairingRequest request) async {
    final response = await _session.post(
      'relay/pairing/',
      body: request.toJson(),
    );
    _session.throwApiException(response, 'Relay pairing failed with status');
    return RelayPairing.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Whether the shop takes sign-ins from the internet, asked on the relay's
  /// sign-in route. Throws [PosApiException] with the relay's own status when
  /// the relay refuses (401: no such paid installation; 503: the shop's
  /// server is not connected).
  Future<RemoteSignInStatus> fetchRemoteSignInStatus() async {
    final response = await _session.get('relay/remote-sign-in/');
    _session.throwApiException(
      response,
      'Remote sign-in status failed with status',
    );
    return RemoteSignInStatus.fromJson(
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
