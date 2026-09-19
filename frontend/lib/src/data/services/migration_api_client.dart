import 'dart:typed_data';

import '../models/migration.dart';
import '../models/migration_collapse.dart';
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

/// A chunk the server will never accept, however many times we send it.
///
/// The retry loop exists for a shop's Wi-Fi dropping mid-transfer. A 413 from
/// the front door or a 403 from an expired session is not that: resending tens
/// of megabytes four times only delays telling the person what went wrong.
class MigrationChunkRejected implements Exception {
  const MigrationChunkRejected(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
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
    _session.ensureSuccess(
      response,
      'Begin migration upload failed with status',
    );
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
    final body = decoded is Map<String, Object?>
        ? decoded
        : const <String, Object?>{};
    if (response.statusCode == 409) {
      return MigrationChunkResult(
        receivedBytes: (body['received_bytes'] as num?)?.toInt() ?? 0,
        conflicted: true,
      );
    }
    if (response.statusCode == 413) {
      // The proxy in front of the backend refused the body. Retrying cannot
      // help, and the server is the one that chose this chunk size, so say so
      // rather than blaming the network.
      throw const MigrationChunkRejected(
        413,
        'الخادم رفض حجم الجزء المُرسَل. راجع إعداد حجم الأجزاء على الخادم.',
      );
    }
    if (response.statusCode >= 400 &&
        response.statusCode < 500 &&
        response.statusCode != 429) {
      throw MigrationChunkRejected(
        response.statusCode,
        '${body['detail'] ?? 'تعذر رفع الملف'} (${response.statusCode})',
      );
    }
    _session.ensureSuccess(
      response,
      'Migration chunk upload failed with status',
    );
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
    final body = decoded is Map<String, Object?>
        ? decoded
        : const <String, Object?>{};
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

  // --- the collapse (§12) ----------------------------------------------

  /// Asks the server what a one-product-per-handset catalogue would collapse
  /// into. Reads the file; writes nothing to the shop.
  Future<CollapsePlan> proposeCollapse(int sourceId) async {
    final response = await _session.post(
      'migration/sources/$sourceId/collapse/',
      timeout: PosApiSession.longRunningRequestTimeout,
    );
    _session.ensureSuccess(response, 'Collapse proposal failed with status');
    return CollapsePlan.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<CollapsePlan> fetchCollapsePlan(int planId) async {
    final response = await _session.get('migration/collapse-plans/$planId/');
    _session.ensureSuccess(
      response,
      'Collapse plan request failed with status',
    );
    return CollapsePlan.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<CollapsePlan>> fetchCollapsePlans({int? sourceId}) async {
    final response = await _session.get(
      'migration/collapse-plans/',
      query: {if (sourceId != null) 'source': '$sourceId'},
    );
    _session.ensureSuccess(
      response,
      'Collapse plans request failed with status',
    );
    return _decodeList(
      _session.decodedBody(response),
    ).map(CollapsePlan.fromJson).toList();
  }

  Future<List<CollapseCluster>> fetchCollapseClusters(int planId) async {
    final response = await _session.get(
      'migration/collapse-plans/$planId/clusters/',
    );
    _session.ensureSuccess(
      response,
      'Collapse clusters request failed with status',
    );
    final decoded = _session.decodedBody(response);
    return [
      if (decoded is List)
        for (final item in decoded)
          if (item is Map<String, Object?>) CollapseCluster.fromJson(item),
    ];
  }

  Future<CollapseCandidatePage> fetchCollapseCandidates(
    int planId, {
    int page = 1,
    String? decision,
    String? stemKey,
    bool needsReview = false,
    String search = '',
  }) async {
    final response = await _session.get(
      'migration/collapse-plans/$planId/candidates/',
      query: {
        'page': '$page',
        'decision': ?decision,
        'stem_key': ?stemKey,
        if (needsReview) 'needs_review': '1',
        if (search.isNotEmpty) 'search': search,
      },
    );
    _session.ensureSuccess(
      response,
      'Collapse candidates request failed with status',
    );
    return CollapseCandidatePage.fromAny(_session.decodedBody(response));
  }

  /// Edits one row. Returns the row and the recounted headline together, so the
  /// screen never shows a total that predates the edit that produced it.
  Future<({CollapseCandidate candidate, CollapseStats stats})>
  updateCollapseCandidate(int candidateId, Map<String, Object?> changes) async {
    final response = await _session.patch(
      'migration/collapse-candidates/$candidateId/',
      body: changes,
    );
    _session.ensureSuccess(
      response,
      'Collapse candidate update failed with status',
    );
    final body = _session.decodedBody(response) as Map<String, Object?>;
    return (
      candidate: CollapseCandidate.fromJson(
        (body['candidate'] as Map<String, Object?>?) ?? const {},
      ),
      stats: CollapseStats.fromJson(
        (body['stats'] as Map<String, Object?>?) ?? const {},
      ),
    );
  }

  /// Renames a proposed product — which is also how two of them are merged.
  Future<CollapsePlan> renameCollapseCluster(
    int planId, {
    required String stemKey,
    required String stem,
  }) async {
    final response = await _session.post(
      'migration/collapse-plans/$planId/rename/',
      body: {'stem_key': stemKey, 'stem': stem},
    );
    _session.ensureSuccess(response, 'Collapse rename failed with status');
    final body = _session.decodedBody(response) as Map<String, Object?>;
    return CollapsePlan.fromJson(
      (body['plan'] as Map<String, Object?>?) ?? const {},
    );
  }

  Future<CollapsePlan> approveCollapsePlan(int planId) async {
    final response = await _session.post(
      'migration/collapse-plans/$planId/approve/',
    );
    _session.ensureSuccess(response, 'Collapse approval failed with status');
    return CollapsePlan.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
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
