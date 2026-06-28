import '../models/migration.dart';
import 'api_session.dart';

class MigrationApiClient {
  const MigrationApiClient(this._session);

  final PosApiSession _session;

  Future<MigrationCatalog> fetchCatalog() async {
    final response = await _session.get('migration/systems/');
    _session.ensureSuccess(response, 'Migration systems request failed with status');
    return MigrationCatalog.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<MigrationSource>> fetchSources() async {
    final response = await _session.get('migration/sources/');
    _session.ensureSuccess(response, 'Migration sources request failed with status');
    return _decodeList(_session.decodedBody(response))
        .map(MigrationSource.fromJson)
        .toList();
  }

  Future<MigrationSource> createSource(MigrationSourceDraft draft) async {
    final response = await _session.post('migration/sources/', body: draft.toJson());
    _session.ensureSuccess(response, 'Create migration source failed with status');
    return MigrationSource.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<MigrationSource> updateSource(int id, MigrationSourceDraft draft) async {
    final response = await _session.patch(
      'migration/sources/$id/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(response, 'Update migration source failed with status');
    return MigrationSource.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteSource(int id) async {
    final response = await _session.delete('migration/sources/$id/');
    _session.ensureSuccess(response, 'Delete migration source failed with status');
  }

  /// Discovery only — broadcasts an SSRP request and lists reachable SQL Server
  /// instances. No credentials are sent; the operator picks the target.
  Future<List<DiscoveredServer>> discoverServers() async {
    final response = await _session.post('migration/sources/discover/');
    _session.ensureSuccess(response, 'Migration server discovery failed with status');
    final decoded = _session.decodedBody(response);
    final servers = decoded is Map<String, Object?> ? decoded['servers'] : null;
    return [
      if (servers is List)
        for (final item in servers)
          if (item is Map<String, Object?>) DiscoveredServer.fromJson(item),
    ];
  }

  Future<MigrationConnectionTest> testConnection(int id) async {
    final response = await _session.post('migration/sources/$id/test/');
    _session.ensureSuccess(response, 'Migration connection test failed with status');
    return MigrationConnectionTest.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<CompatibilityReport> checkCompatibility(int id) async {
    final response = await _session.post('migration/sources/$id/check/');
    _session.ensureSuccess(response, 'Migration compatibility check failed with status');
    return CompatibilityReport.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<MigrationRun> startRun({
    required int sourceId,
    required String mode,
    required List<String> entities,
    Map<String, Object?> options = const {},
  }) async {
    final response = await _session.post(
      'migration/runs/',
      body: {
        'source': sourceId,
        'mode': mode,
        'selected_entities': entities,
        'options': options,
      },
    );
    _session.ensureSuccess(response, 'Start migration run failed with status');
    return MigrationRun.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<MigrationRun> fetchRun(int id) async {
    final response = await _session.get('migration/runs/$id/');
    _session.ensureSuccess(response, 'Migration run request failed with status');
    return MigrationRun.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<MigrationRun>> fetchRuns({int? sourceId}) async {
    final response = await _session.get(
      'migration/runs/',
      query: {if (sourceId != null) 'source': '$sourceId'},
    );
    _session.ensureSuccess(response, 'Migration runs request failed with status');
    return _decodeList(_session.decodedBody(response))
        .map(MigrationRun.fromJson)
        .toList();
  }

  Future<MigrationIssuePage> fetchIssues(
    int runId, {
    int page = 1,
    String? severity,
  }) async {
    final response = await _session.get(
      'migration/runs/$runId/issues/',
      query: {
        'page': '$page',
        'severity': ?severity,
      },
    );
    _session.ensureSuccess(response, 'Migration issues request failed with status');
    return MigrationIssuePage.fromAny(_session.decodedBody(response));
  }

  List<Map<String, Object?>> _decodeList(Object? decoded) {
    if (decoded is Map<String, Object?> && decoded['results'] is List) {
      return [
        for (final item in decoded['results'] as List)
          if (item is Map<String, Object?>) item,
      ];
    }
    if (decoded is List) {
      return [
        for (final item in decoded)
          if (item is Map<String, Object?>) item,
      ];
    }
    return const [];
  }
}
