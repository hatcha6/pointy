import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/migration.dart';
import 'package:pointy_frontend/src/data/models/migration_collapse.dart';
import 'package:pointy_frontend/src/data/repositories/migration_repository.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/migration_api_client.dart';
import 'package:pointy_frontend/src/data/services/migration_uploader.dart';

/// One fake for the whole migration feature, so a new repository method does not
/// mean a new stub in three test files.
///
/// Every method has a defensible do-nothing answer; a test overrides only what
/// it is actually about.
class FakeMigrationRepository implements MigrationRepository {
  FakeMigrationRepository({
    this.sources = const [],
    this.runs = const [],
    this.plans = const [],
    this.clusters = const [],
    this.candidates = const [],
  });

  final List<Map<String, Object?>> sources;
  final List<Map<String, Object?>> runs;
  final List<Map<String, Object?>> plans;
  final List<Map<String, Object?>> clusters;
  final List<Map<String, Object?>> candidates;

  /// What each write was asked to do, for a test that cares about the request
  /// rather than the answer.
  final List<Map<String, Object?>> startedRuns = [];

  /// Source ids the wizard asked the server to delete.
  final List<int> discarded = [];

  /// Held open by a test that needs an upload to still be in flight while it
  /// does something else — cancelling it, for instance. Left null, an upload
  /// finishes immediately, which is what every other test wants.
  Completer<Result<MigrationSource>>? pendingUpload;
  final List<Map<String, Object?>> candidateEdits = [];
  final List<({String stemKey, String stem})> renames = [];
  int approvals = 0;
  int proposals = 0;

  @override
  Future<Result<MigrationCatalog>> loadCatalog() async => Ok(
    MigrationCatalog.fromJson(const {
      'systems': [
        {
          'system_key': 'fahd',
          'display_name': 'برنامج فهد',
          'supported_entities': ['product'],
          'versions': ['fahd-mdb-recon-1'],
          'implemented': true,
          'supports_stock_filter': true,
        },
      ],
      'entities': [
        {
          'entity_type': 'category',
          'label': 'Categories',
          'implemented': true,
          'dependencies': <String>[],
        },
        {
          'entity_type': 'product',
          'label': 'Products',
          'implemented': true,
          'dependencies': ['category'],
        },
        {
          'entity_type': 'customer',
          'label': 'Customers',
          'implemented': true,
          'dependencies': <String>[],
        },
        {
          'entity_type': 'party_balance',
          'label': 'Customer & supplier balances',
          'implemented': true,
          'dependencies': ['customer'],
        },
        {
          'entity_type': 'sale',
          'label': 'Sales',
          'implemented': true,
          'dependencies': ['customer', 'product'],
        },
      ],
      'scopes': [
        {
          'key': 'everything',
          'label': 'كل شيء',
          'description': '',
          'entities': [
            'category',
            'product',
            'customer',
            'party_balance',
            'sale',
          ],
          'options': {'stock_source': 'snapshot'},
          'is_preset': true,
        },
        {
          'key': 'opening_position',
          'label': 'نبدأ من الوضع الحالي',
          'description': '',
          'entities': ['category', 'product', 'customer', 'party_balance'],
          'options': {'stock_source': 'none', 'carry_costs': true},
          'is_preset': true,
        },
        {
          'key': 'costs_only',
          'label': 'تحديث التكلفة فقط',
          'description': '',
          'entities': ['stock'],
          'options': {
            'stock_source': 'none',
            'carry_costs': true,
            'attach_to_catalogue': true,
          },
          'is_preset': true,
        },
        {
          'key': 'custom',
          'label': 'تحديد يدوي',
          'description': '',
          'entities': null,
          'options': <String, Object?>{},
          'is_preset': false,
        },
      ],
      'upload': {'chunk_size': 1024, 'max_bytes': 8589934592},
    }),
  );

  @override
  Future<Result<List<MigrationSource>>> loadSources() async =>
      Ok(sources.map(MigrationSource.fromJson).toList());

  @override
  Future<Result<MigrationSource>> loadSource(int id) async =>
      Ok(MigrationSource.fromJson(sources.first));

  @override
  Future<Result<List<MigrationRun>>> loadRuns({int? sourceId}) async =>
      Ok(runs.map(MigrationRun.fromJson).toList());

  @override
  Future<Result<MigrationRun>> loadRun(int id) async =>
      Ok(MigrationRun.fromJson(runs.first));

  @override
  Future<Result<MigrationRun>> startRun({
    required int sourceId,
    required String mode,
    required List<String> entities,
    String? scope,
    Map<String, Object?> options = const {},
  }) async {
    startedRuns.add({
      'mode': mode,
      'entities': entities,
      'scope': scope,
      'options': options,
    });
    return Ok(MigrationRun.fromJson(const {'id': 1, 'status': 'queued'}));
  }

  @override
  Future<Result<MigrationIssuePage>> loadIssues(
    int runId, {
    int page = 1,
    String? severity,
  }) async => const Ok(MigrationIssuePage(issues: [], hasMore: false));

  /// A real uploader over a client that answers nothing.
  ///
  /// The view model holds this to cancel it; the transfer itself is [uploadFile]
  /// here, so the uploader never issues a request.
  @override
  MigrationUploader newUploader() => MigrationUploader(
    MigrationApiClient(
      PosApiSession(
        client: MockClient((_) async => http.Response('{}', 200)),
        baseUrl: 'http://pointy.test/api',
      ),
    ),
  );

  @override
  Future<Result<MigrationSource>> uploadFile(
    PlatformFile file, {
    required MigrationUploader uploader,
    MigrationSource? resuming,
    void Function(MigrationUploadProgress)? onProgress,
  }) {
    final pending = pendingUpload;
    if (pending != null) return pending.future;
    return Future.value(Ok(MigrationSource.fromJson(sources.first)));
  }

  @override
  Future<Result<MigrationSource>> completeUpload(int id) async =>
      Ok(MigrationSource.fromJson(sources.first));

  @override
  Future<Result<MigrationSource>> discardSource(int id) async {
    discarded.add(id);
    return Ok(
      MigrationSource.fromJson({
        ...sources.first,
        'upload_state': 'purged',
        'is_purged': true,
      }),
    );
  }

  // --- the collapse (§12) ----------------------------------------------

  @override
  Future<Result<CollapsePlan>> proposeCollapse(int sourceId) async {
    proposals += 1;
    return Ok(CollapsePlan.fromJson(plans.isEmpty ? const {} : plans.first));
  }

  @override
  Future<Result<CollapsePlan>> loadCollapsePlan(int planId) async =>
      Ok(CollapsePlan.fromJson(plans.isEmpty ? const {} : plans.first));

  @override
  Future<Result<List<CollapsePlan>>> loadCollapsePlans({int? sourceId}) async =>
      Ok(plans.map(CollapsePlan.fromJson).toList());

  @override
  Future<Result<List<CollapseCluster>>> loadCollapseClusters(
    int planId,
  ) async => Ok(clusters.map(CollapseCluster.fromJson).toList());

  @override
  Future<Result<CollapseCandidatePage>> loadCollapseCandidates(
    int planId, {
    int page = 1,
    String? decision,
    String? stemKey,
    bool needsReview = false,
    String search = '',
  }) async {
    final rows = candidates.map(CollapseCandidate.fromJson).toList();
    return Ok(
      CollapseCandidatePage(
        candidates: [
          for (final row in rows)
            if (decision == null || row.decision == decision)
              if (!needsReview || row.needsReview)
                if (stemKey == null || row.stemKey == stemKey) row,
        ],
        hasMore: false,
      ),
    );
  }

  @override
  Future<Result<({CollapseCandidate candidate, CollapseStats stats})>>
  updateCollapseCandidate(int candidateId, Map<String, Object?> changes) async {
    candidateEdits.add({'id': candidateId, ...changes});
    final row = candidates.firstWhere(
      (item) => item['id'] == candidateId,
      orElse: () => candidates.first,
    );
    return Ok((
      candidate: CollapseCandidate.fromJson({
        ...row,
        ...changes,
        'edited': true,
      }),
      stats: CollapsePlan.fromJson(
        plans.isEmpty ? const {} : plans.first,
      ).stats,
    ));
  }

  @override
  Future<Result<CollapsePlan>> renameCollapseCluster(
    int planId, {
    required String stemKey,
    required String stem,
  }) async {
    renames.add((stemKey: stemKey, stem: stem));
    return Ok(CollapsePlan.fromJson(plans.isEmpty ? const {} : plans.first));
  }

  @override
  Future<Result<CollapsePlan>> approveCollapsePlan(int planId) async {
    approvals += 1;
    final base = plans.isEmpty ? const <String, Object?>{} : plans.first;
    return Ok(
      CollapsePlan.fromJson({
        ...base,
        'status': 'approved',
        'is_editable': false,
      }),
    );
  }
}
