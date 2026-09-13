import '../../core/server_state.dart';
import 'api_session.dart';

/// What `GET state/` answers: the counters, and how often to ask again.
class ServerStateSnapshot {
  const ServerStateSnapshot({
    required this.versions,
    required this.pollIntervalSeconds,
    required this.enabled,
  });

  final Map<String, String> versions;
  final int pollIntervalSeconds;

  /// False when the backend publishes no versions (feature off, or its Redis
  /// is unusable). The client must then keep trusting its TTLs instead of
  /// waiting for a bump that will never come.
  final bool enabled;
}

class ServerStateApiClient {
  const ServerStateApiClient(this._session);

  final PosApiSession _session;

  /// The poll. Rides the conditional-GET cache, so an unchanged vector costs
  /// an empty 304 on the wire and the stored body is replayed locally.
  Future<ServerStateSnapshot> fetchState() async {
    final response = await _session.get('state/', conditionalCache: true);
    _session.ensureSuccess(response, 'State request failed with status');
    final body = _session.decodedBody(response) as Map<String, Object?>;
    final rawVersions = body['versions'];
    return ServerStateSnapshot(
      versions: rawVersions is Map
          ? {
              for (final entry in rawVersions.entries)
                entry.key.toString(): entry.value.toString(),
            }
          : const {},
      pollIntervalSeconds:
          int.tryParse('${body['poll_interval_seconds']}') ??
          defaultServerStatePollSeconds,
      enabled: body['enabled'] == true,
    );
  }
}

/// Used until the first successful poll says otherwise, and when an older
/// backend answers without the field.
const int defaultServerStatePollSeconds = 15;

/// Convenience for callers that only have a header to merge.
Map<String, String> serverStateFromHeaders(Map<String, String> headers) =>
    parseServerStateHeader(headers['x-pointy-state']);
