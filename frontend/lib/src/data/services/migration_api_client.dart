import 'dart:typed_data';

import '../models/migration.dart';
import 'api_session.dart';

/// The outcome of one chunk PUT: where the server now is, and whether it
/// rejected our idea of where the file ended.
class MigrationChunkResult {
  const MigrationChunkResult({
    required this.receivedBytes,
    required this.conflicted,
  });

  final int receivedBytes;
  final bool conflicted;
}

class MigrationApiClient {
  const MigrationApiClient(this._session);

  final PosApiSession _session;

  Future<MigrationCatalog> fetchCatalog() async {
    final response = await _session.get('migration/systems/');
    _session.ensureSuccess(
      response,
      'Migration systems request failed with status',
    );
    return MigrationCatalog.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<MigrationSource>> fetchSources() async {
    final response = await _session.get('migration/sources/');
    _session.ensureSuccess(
      response,
      'Migration sources request failed with status',
    );
    return _decodeList(
      _session.decodedBody(response),
    ).map(MigrationSource.fromJson).toList();
  }

  Future<MigrationSource> fetchSource(int id) async {
    final response = await _session.get('migration/sources/$id/');
    _session.ensureSuccess(
      response,
      'Migration source request failed with status',
    );
    return MigrationSource.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Opens an upload: reserves the row and an empty file, and reports the chunk
  /// size to send. Nothing is transferred yet.
  Future<MigrationUploadTicket> beginUpload({
    required String filename,
    required int sizeBytes,
  }) async {
    final response = await _session.post(
      'migration/sources/begin/',
      body: {'filename': filename, 'size_bytes': sizeBytes},
    );
    _session.ensureSuccess(response, 'Begin migration upload failed with status');
    return MigrationUploadTicket.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Sends one chunk at [offset].
  ///
  /// Returns the server's new offset on success. A **409** means the server
  /// disagreed about where the file ends — it carries the real offset, and the
  /// caller re-syncs to it rather than writing into the wrong place, which
  /// would corrupt the database silently.
  Future<MigrationChunkResult> uploadChunk({
    required int sourceId,
    required int offset,
    required Uint8List bytes,
  }) async {
    final response = await _session.putBytes(
      'migration/sources/$sourceId/chunk/',
      bytes: bytes,
      queryParameters: {'offset': '$offset'},
      timeout: PosApiSession.longRunningRequestTimeout,
    );
    final decoded = _session.decodedBody(response);
    final body = decoded is Map<String, Object?> ? decoded : const <String, Object?>{};
    if (response.statusCode == 409) {
      return MigrationChunkResult(
        receivedBytes: (body['received_bytes'] as num?)?.toInt() ?? 0,
        conflicted: true,
      );
    }
    _session.ensureSuccess(response, 'Migration chunk upload failed with status');
    return MigrationChunkResult(
      receivedBytes: (body['received_bytes'] as num?)?.toInt() ?? 0,
      conflicted: false,
    );
  }

  /// Verifies the received bytes and starts conversion + identification.
  Future<MigrationSource> completeUpload(
    int sourceId, {
    String checksumSha256 = '',
  }) async {
    final response = await _session.post(
      'migration/sources/$sourceId/complete/',
      body: {'checksum_sha256': checksumSha256},
      timeout: PosApiSession.longRunningRequestTimeout,
    );
    _session.ensureSuccess(
      response,
      'Complete migration upload failed with status',
    );
    return MigrationSource.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Deletes the file from the server now.
  Future<MigrationSource> discardSource(int id) async {
    final response = await _session.post('migration/sources/$id/discard/');
    _session.ensureSuccess(
      response,
      'Discard migration source failed with status',
    );
    final decoded = _session.decodedBody(response);
    final body = decoded is Map<String, Object?> ? decoded : const <String, Object?>{};
    return MigrationSource.fromJson(
      (body['source'] as Map<String, Object?>?) ?? const {},
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
    _session.ensureSuccess(
      response,
      'Migration run request failed with status',
    );
    return MigrationRun.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<MigrationRun>> fetchRuns({int? sourceId}) async {
    final response = await _session.get(
      'migration/runs/',
      query: {if (sourceId != null) 'source': '$sourceId'},
    );
    _session.ensureSuccess(
      response,
      'Migration runs request failed with status',
    );
    return _decodeList(
      _session.decodedBody(response),
    ).map(MigrationRun.fromJson).toList();
  }

  Future<MigrationIssuePage> fetchIssues(
    int runId, {
    int page = 1,
    String? severity,
  }) async {
    final response = await _session.get(
      'migration/runs/$runId/issues/',
      query: {'page': '$page', 'severity': ?severity},
    );
    _session.ensureSuccess(
      response,
      'Migration issues request failed with status',
    );
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
