import 'package:file_picker/file_picker.dart';

import '../../core/result.dart';
import '../models/migration.dart';
import '../models/migration_collapse.dart';
import '../services/migration_uploader.dart';
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

  Future<Result<MigrationSource>> loadSource(int id) {
    return Result.guard(() => _service.fetchMigrationSource(id));
  }

  /// Sends a picked file up in resumable chunks.
  ///
  /// Returns an uploader-backed future; [onProgress] fires as bytes land, and
  /// [uploader] is the handle a caller keeps to cancel mid-transfer.
  Future<Result<MigrationSource>> uploadFile(
    PlatformFile file, {
    required MigrationUploader uploader,
    MigrationSource? resuming,
    void Function(MigrationUploadProgress)? onProgress,
  }) {
    return Result.guard(
      () => uploader.upload(file, resuming: resuming, onProgress: onProgress),
    );
  }

  MigrationUploader newUploader() => _service.newMigrationUploader();

  Future<Result<MigrationSource>> completeUpload(int id) {
    return Result.guard(() => _service.completeMigrationUpload(id));
  }

  Future<Result<MigrationSource>> discardSource(int id) {
    return Result.guard(() => _service.discardMigrationSource(id));
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

  // --- the collapse (§12) ----------------------------------------------

  Future<Result<CollapsePlan>> proposeCollapse(int sourceId) {
    return Result.guard(() => _service.proposeCollapse(sourceId));
  }

  Future<Result<CollapsePlan>> loadCollapsePlan(int planId) {
    return Result.guard(() => _service.fetchCollapsePlan(planId));
  }

  Future<Result<List<CollapsePlan>>> loadCollapsePlans({int? sourceId}) {
    return Result.guard(() => _service.fetchCollapsePlans(sourceId: sourceId));
  }

  Future<Result<List<CollapseCluster>>> loadCollapseClusters(int planId) {
    return Result.guard(() => _service.fetchCollapseClusters(planId));
  }

  Future<Result<CollapseCandidatePage>> loadCollapseCandidates(
    int planId, {
    int page = 1,
    String? decision,
    String? stemKey,
    bool needsReview = false,
    String search = '',
  }) {
    return Result.guard(
      () => _service.fetchCollapseCandidates(
        planId,
        page: page,
        decision: decision,
        stemKey: stemKey,
        needsReview: needsReview,
        search: search,
      ),
    );
  }

  Future<Result<({CollapseCandidate candidate, CollapseStats stats})>>
  updateCollapseCandidate(int candidateId, Map<String, Object?> changes) {
    return Result.guard(
      () => _service.updateCollapseCandidate(candidateId, changes),
    );
  }

  Future<Result<CollapsePlan>> renameCollapseCluster(
    int planId, {
    required String stemKey,
    required String stem,
  }) {
    return Result.guard(
      () =>
          _service.renameCollapseCluster(planId, stemKey: stemKey, stem: stem),
    );
  }

  Future<Result<CollapsePlan>> approveCollapsePlan(int planId) {
    return Result.guard(() => _service.approveCollapsePlan(planId));
  }
}
