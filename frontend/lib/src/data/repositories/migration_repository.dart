import '../../core/result.dart';
import '../models/migration.dart';
import '../services/pos_api_service.dart';

class MigrationRepository {
  MigrationRepository(this._service);

  final PosApiService _service;

  Future<Result<MigrationCatalog>> loadCatalog() {
    return Result.guard(() => _service.fetchMigrationCatalog());
  }

  Future<Result<List<MigrationSource>>> loadSources() {
    return Result.guard(() => _service.fetchMigrationSources());
  }

  Future<Result<MigrationSource>> createSource(MigrationSourceDraft draft) {
    return Result.guard(() => _service.createMigrationSource(draft));
  }

  Future<Result<MigrationSource>> updateSource(
    int id,
    MigrationSourceDraft draft,
  ) {
    return Result.guard(() => _service.updateMigrationSource(id, draft));
  }

  Future<Result<void>> deleteSource(int id) {
    return Result.guard(() => _service.deleteMigrationSource(id));
  }

  Future<Result<List<DiscoveredServer>>> discoverServers() {
    return Result.guard(() => _service.discoverMigrationServers());
  }

  Future<Result<MigrationConnectionTest>> testConnection(int id) {
    return Result.guard(() => _service.testMigrationConnection(id));
  }

  Future<Result<CompatibilityReport>> checkCompatibility(int id) {
    return Result.guard(() => _service.checkMigrationCompatibility(id));
  }

  Future<Result<MigrationRun>> startRun({
    required int sourceId,
    required String mode,
    required List<String> entities,
    Map<String, Object?> options = const {},
  }) {
    return Result.guard(
      () => _service.startMigrationRun(
        sourceId: sourceId,
        mode: mode,
        entities: entities,
        options: options,
      ),
    );
  }

  Future<Result<MigrationRun>> loadRun(int id) {
    return Result.guard(() => _service.fetchMigrationRun(id));
  }

  Future<Result<List<MigrationRun>>> loadRuns({int? sourceId}) {
    return Result.guard(() => _service.fetchMigrationRuns(sourceId: sourceId));
  }

  Future<Result<MigrationIssuePage>> loadIssues(
    int runId, {
    int page = 1,
    String? severity,
  }) {
    return Result.guard(
      () =>
          _service.fetchMigrationIssues(runId, page: page, severity: severity),
    );
  }
}
