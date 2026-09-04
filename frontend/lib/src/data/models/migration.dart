/// A POS Pointy knows how to read.
///
/// Nobody picks from this list — the system is worked out from the uploaded
/// file's schema. It is here so the screen can answer "will my system work?"
/// before someone spends twenty minutes uploading.
class MigrationSystem {
  const MigrationSystem({
    required this.systemKey,
    required this.displayName,
    required this.supportedEntities,
    required this.versions,
    required this.implemented,
  });

  final String systemKey;
  final String displayName;
  final List<String> supportedEntities;
  final List<String> versions;
  final bool implemented;

  factory MigrationSystem.fromJson(Map<String, Object?> json) {
    return MigrationSystem(
      systemKey: _str(json['system_key']),
      displayName: _str(json['display_name']),
      supportedEntities: _stringList(json['supported_entities']),
      versions: _stringList(json['versions']),
      implemented: json['implemented'] as bool? ?? false,
    );
  }
}

class MigrationEntitySpec {
  const MigrationEntitySpec({
    required this.entityType,
    required this.label,
    required this.implemented,
  });

  final String entityType;
  final String label;
  final bool implemented;

  factory MigrationEntitySpec.fromJson(Map<String, Object?> json) {
    return MigrationEntitySpec(
      entityType: _str(json['entity_type']),
      label: _str(json['label']),
      implemented: json['implemented'] as bool? ?? false,
    );
  }
}

/// Upload limits the server advertises, so the client never has to guess them.
class MigrationUploadConfig {
  const MigrationUploadConfig({
    required this.chunkSize,
    required this.maxBytes,
    required this.acceptedExtensions,
  });

  final int chunkSize;
  final int maxBytes;
  final List<String> acceptedExtensions;

  static const fallback = MigrationUploadConfig(
    chunkSize: 16 * 1024 * 1024,
    maxBytes: 8 * 1024 * 1024 * 1024,
    acceptedExtensions: ['.mdb', '.accdb', '.sqlite', '.sqlite3', '.db'],
  );

  /// Extensions without the leading dot, which is what `file_picker` wants.
  List<String> get pickerExtensions => [
    for (final extension in acceptedExtensions)
      extension.startsWith('.') ? extension.substring(1) : extension,
  ];

  factory MigrationUploadConfig.fromJson(Map<String, Object?> json) {
    if (json.isEmpty) return fallback;
    return MigrationUploadConfig(
      chunkSize: _intOrNull(json['chunk_size']) ?? fallback.chunkSize,
      maxBytes: _intOrNull(json['max_bytes']) ?? fallback.maxBytes,
      acceptedExtensions: _stringList(json['accepted_extensions']).isEmpty
          ? fallback.acceptedExtensions
          : _stringList(json['accepted_extensions']),
    );
  }
}

class MigrationCatalog {
  const MigrationCatalog({
    required this.systems,
    required this.entities,
    required this.upload,
  });

  final List<MigrationSystem> systems;
  final List<MigrationEntitySpec> entities;
  final MigrationUploadConfig upload;

  factory MigrationCatalog.fromJson(Map<String, Object?> json) {
    return MigrationCatalog(
      systems: [
        for (final item in _list(json['systems'])) MigrationSystem.fromJson(item),
      ],
      entities: [
        for (final item in _list(json['entities']))
          MigrationEntitySpec.fromJson(item),
      ],
      upload: MigrationUploadConfig.fromJson(_map(json['upload'])),
    );
  }
}

/// One step of a long job, as the server reports it.
///
/// A twenty-minute conversion needs to say what it is doing, not just how far a
/// single bar has crept — at that length "62%" and "hung" look the same.
class MigrationStage {
  const MigrationStage({
    required this.key,
    required this.label,
    required this.status,
    required this.percent,
    required this.detail,
    required this.counts,
  });

  final String key;
  final String label;
  final String status; // pending | running | done | failed | skipped
  final int percent;
  final String detail;
  final Map<String, Object?> counts;

  bool get isRunning => status == 'running';
  bool get isDone => status == 'done';
  bool get isFailed => status == 'failed';
  bool get isSkipped => status == 'skipped';
  bool get isPending => status == 'pending';
  bool get isSettled => isDone || isFailed || isSkipped;

  factory MigrationStage.fromJson(Map<String, Object?> json) {
    return MigrationStage(
      key: _str(json['key']),
      label: _str(json['label']),
      status: _str(json['status'], fallback: 'pending'),
      percent: _int(json['percent']),
      detail: _str(json['detail']),
      counts: _map(json['counts']),
    );
  }
}

/// How much of what a file holds — shown before the owner commits to anything.
class MigrationEntityCount {
  const MigrationEntityCount({
    required this.entityType,
    required this.count,
    required this.from,
    required this.to,
  });

  final String entityType;
  final int count;
  final String from;
  final String to;

  bool get hasRange => from.isNotEmpty || to.isNotEmpty;
}

class MigrationAnalysis {
  const MigrationAnalysis({
    required this.entities,
    required this.historyFrom,
    required this.historyTo,
  });

  final List<MigrationEntityCount> entities;
  final String historyFrom;
  final String historyTo;

  static const empty = MigrationAnalysis(
    entities: [],
    historyFrom: '',
    historyTo: '',
  );

  bool get isEmpty => entities.isEmpty;
  bool get hasHistory => historyFrom.isNotEmpty || historyTo.isNotEmpty;

  int countFor(String entityType) {
    for (final entity in entities) {
      if (entity.entityType == entityType) return entity.count;
    }
    return 0;
  }

  factory MigrationAnalysis.fromJson(Map<String, Object?> json) {
    final raw = _map(json['entities']);
    final entities = <MigrationEntityCount>[];
    raw.forEach((key, value) {
      final entry = _map(value);
      entities.add(
        MigrationEntityCount(
          entityType: key,
          count: _int(entry['count']),
          from: _str(entry['from']),
          to: _str(entry['to']),
        ),
      );
    });
    entities.sort((a, b) => b.count.compareTo(a.count));
    return MigrationAnalysis(
      entities: entities,
      historyFrom: _str(json['history_from']),
      historyTo: _str(json['history_to']),
    );
  }
}

/// Why a file was, or was not, recognised.
class MigrationDetection {
  const MigrationDetection({
    required this.matched,
    required this.systemKey,
    required this.displayName,
    required this.detectedVersion,
  });

  final bool matched;
  final String systemKey;
  final String displayName;
  final String detectedVersion;

  static const unknown = MigrationDetection(
    matched: false,
    systemKey: '',
    displayName: '',
    detectedVersion: '',
  );

  factory MigrationDetection.fromJson(Map<String, Object?> json) {
    if (json.isEmpty) return unknown;
    return MigrationDetection(
      matched: json['matched'] as bool? ?? false,
      systemKey: _str(json['system_key']),
      displayName: _str(json['display_name']),
      detectedVersion: _str(json['detected_version']),
    );
  }
}

/// An uploaded legacy database, and everything derived from it.
class MigrationSource {
  const MigrationSource({
    required this.id,
    required this.name,
    required this.originalFilename,
    required this.declaredSizeBytes,
    required this.receivedBytes,
    required this.uploadPercent,
    required this.uploadState,
    required this.stagedSizeBytes,
    required this.preparedSizeBytes,
    required this.stages,
    required this.errorMessage,
    required this.systemKey,
    required this.detectedVersion,
    required this.detection,
    required this.analysis,
    required this.supportedEntities,
    required this.lastRunAt,
    required this.purgedAt,
  });

  final int id;
  final String name;
  final String originalFilename;
  final int declaredSizeBytes;
  final int receivedBytes;
  final int uploadPercent;

  /// uploading | uploaded | preparing | ready | failed | purged
  final String uploadState;
  final int stagedSizeBytes;
  final int preparedSizeBytes;
  final List<MigrationStage> stages;
  final String errorMessage;
  final String systemKey;
  final String detectedVersion;
  final MigrationDetection detection;
  final MigrationAnalysis analysis;
  final List<String> supportedEntities;
  final DateTime? lastRunAt;
  final DateTime? purgedAt;

  bool get isUploading => uploadState == 'uploading';
  bool get isReady => uploadState == 'ready';
  bool get isFailed => uploadState == 'failed';
  bool get isPurged => uploadState == 'purged';

  /// Preparation is in flight: poll, don't offer actions.
  bool get isBusy => uploadState == 'uploaded' || uploadState == 'preparing';

  /// The stage the server is on right now, for a one-line status.
  MigrationStage? get currentStage {
    for (final stage in stages) {
      if (stage.isRunning) return stage;
    }
    return null;
  }

  /// Mean completion across stages — the number for a single bar.
  int get preparationPercent {
    if (stages.isEmpty) return 0;
    var total = 0;
    for (final stage in stages) {
      total += (stage.isDone || stage.isSkipped) ? 100 : stage.percent;
    }
    return total ~/ stages.length;
  }

  factory MigrationSource.fromJson(Map<String, Object?> json) {
    return MigrationSource(
      id: _int(json['id']),
      name: _str(json['name']),
      originalFilename: _str(json['original_filename']),
      declaredSizeBytes: _int(json['declared_size_bytes']),
      receivedBytes: _int(json['received_bytes']),
      uploadPercent: _int(json['upload_percent']),
      uploadState: _str(json['upload_state'], fallback: 'uploading'),
      stagedSizeBytes: _int(json['staged_size_bytes']),
      preparedSizeBytes: _int(json['prepared_size_bytes']),
      stages: [
        for (final item in _list(json['stages'])) MigrationStage.fromJson(item),
      ],
      errorMessage: _str(json['error_message']),
      systemKey: _str(json['system_key']),
      detectedVersion: _str(json['detected_version']),
      detection: MigrationDetection.fromJson(_map(json['detection'])),
      analysis: MigrationAnalysis.fromJson(_map(json['analysis'])),
      supportedEntities: _stringList(json['supported_entities']),
      lastRunAt: _dateOrNull(json['last_run_at']),
      purgedAt: _dateOrNull(json['purged_at']),
    );
  }
}

/// The handle returned when an upload is opened: where to send bytes, and how
/// big each piece should be.
class MigrationUploadTicket {
  const MigrationUploadTicket({required this.source, required this.chunkSize});

  final MigrationSource source;
  final int chunkSize;

  factory MigrationUploadTicket.fromJson(Map<String, Object?> json) {
    return MigrationUploadTicket(
      source: MigrationSource.fromJson(_map(json['source'])),
      chunkSize:
          _intOrNull(json['chunk_size']) ?? MigrationUploadConfig.fallback.chunkSize,
    );
  }
}

class MigrationEntitySummary {
  const MigrationEntitySummary({
    required this.entityType,
    required this.created,
    required this.updated,
    required this.skipped,
    required this.failed,
  });

  final String entityType;
  final int created;
  final int updated;
  final int skipped;
  final int failed;

  int get total => created + updated + skipped + failed;
}

class MigrationRun {
  const MigrationRun({
    required this.id,
    required this.source,
    required this.mode,
    required this.status,
    required this.selectedEntities,
    required this.progressPercent,
    required this.progressMessage,
    required this.currentEntity,
    required this.stages,
    required this.summary,
    required this.errorMessage,
    required this.issueCount,
    required this.createdAt,
    required this.completedAt,
  });

  final int id;
  final int source;
  final String mode; // dry_run | import
  final String status; // queued | running | succeeded | partial | failed
  final List<String> selectedEntities;
  final int progressPercent;
  final String progressMessage;
  final String currentEntity;
  final List<MigrationStage> stages;
  final Map<String, MigrationEntitySummary> summary;
  final String errorMessage;
  final int issueCount;
  final DateTime? createdAt;
  final DateTime? completedAt;

  bool get isDryRun => mode == 'dry_run';
  bool get isActive => status == 'queued' || status == 'running';
  bool get isTerminal => !isActive;
  bool get succeeded => status == 'succeeded';
  bool get partial => status == 'partial';
  bool get failed => status == 'failed';

  int get totalCreated => summary.values.fold(0, (sum, s) => sum + s.created);
  int get totalUpdated => summary.values.fold(0, (sum, s) => sum + s.updated);
  int get totalFailed => summary.values.fold(0, (sum, s) => sum + s.failed);

  List<MigrationEntitySummary> get entitySummaries => summary.values.toList();

  factory MigrationRun.fromJson(Map<String, Object?> json) {
    final summary = <String, MigrationEntitySummary>{};
    final rawSummary = json['summary'];
    if (rawSummary is Map) {
      rawSummary.forEach((key, value) {
        if (value is Map) {
          summary['$key'] = MigrationEntitySummary(
            entityType: '$key',
            created: _int(value['created']),
            updated: _int(value['updated']),
            skipped: _int(value['skipped']),
            failed: _int(value['failed']),
          );
        }
      });
    }
    return MigrationRun(
      id: _int(json['id']),
      source: _int(json['source']),
      mode: _str(json['mode']),
      status: _str(json['status']),
      selectedEntities: _stringList(json['selected_entities']),
      progressPercent: _int(json['progress_percent']),
      progressMessage: _str(json['progress_message']),
      currentEntity: _str(json['current_entity']),
      stages: [
        for (final item in _list(json['stages'])) MigrationStage.fromJson(item),
      ],
      summary: summary,
      errorMessage: _str(json['error_message']),
      issueCount: _int(json['issue_count']),
      createdAt: _dateOrNull(json['created_at']),
      completedAt: _dateOrNull(json['completed_at']),
    );
  }
}

class MigrationIssue {
  const MigrationIssue({
    required this.id,
    required this.entityType,
    required this.sourceKey,
    required this.severity,
    required this.code,
    required this.message,
    required this.detail,
  });

  final int id;
  final String entityType;
  final String sourceKey;
  final String severity; // warning | error
  final String code;
  final String message;
  final Map<String, Object?> detail;

  factory MigrationIssue.fromJson(Map<String, Object?> json) {
    return MigrationIssue(
      id: _int(json['id']),
      entityType: _str(json['entity_type']),
      sourceKey: _str(json['source_key']),
      severity: _str(json['severity']),
      code: _str(json['code']),
      message: _str(json['message']),
      detail: _map(json['detail']),
    );
  }
}

class MigrationIssuePage {
  const MigrationIssuePage({required this.issues, required this.hasMore});

  final List<MigrationIssue> issues;
  final bool hasMore;

  factory MigrationIssuePage.fromAny(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      return MigrationIssuePage(
        issues: [
          for (final item in _list(decoded['results']))
            MigrationIssue.fromJson(item),
        ],
        hasMore: decoded['next'] != null,
      );
    }
    if (decoded is List) {
      return MigrationIssuePage(
        issues: [
          for (final item in decoded)
            if (item is Map<String, Object?>) MigrationIssue.fromJson(item),
        ],
        hasMore: false,
      );
    }
    return const MigrationIssuePage(issues: [], hasMore: false);
  }
}

// --- tolerant parsing helpers ------------------------------------------------

String _str(Object? value, {String fallback = ''}) =>
    value == null ? fallback : '$value';

int _int(Object? value) => _intOrNull(value) ?? 0;

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? value : const {};

List<Map<String, Object?>> _list(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is Map<String, Object?>) item,
];

List<String> _stringList(Object? value) => [
  if (value is List)
    for (final item in value) '$item',
];

DateTime? _dateOrNull(Object? value) {
  if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
  return null;
}
