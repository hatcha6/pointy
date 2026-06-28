// Models for the data-migration feature (importing from an old POS system).

class MigrationSystem {
  const MigrationSystem({
    required this.systemKey,
    required this.displayName,
    required this.requiredTransport,
    required this.supportedEntities,
    required this.versions,
    required this.implemented,
    this.recommendedOptions = const {},
  });

  final String systemKey;
  final String displayName;
  final String requiredTransport;
  final List<String> supportedEntities;
  final List<String> versions;
  final bool implemented;

  /// Suggested transport options (e.g. a legacy ODBC driver + TDS version for an
  /// old SQL Server) used to pre-fill the source's advanced options.
  final Map<String, Object?> recommendedOptions;

  factory MigrationSystem.fromJson(Map<String, Object?> json) {
    return MigrationSystem(
      systemKey: _str(json['system_key']),
      displayName: _str(json['display_name']),
      requiredTransport: _str(json['required_transport']),
      supportedEntities: _stringList(json['supported_entities']),
      versions: _stringList(json['versions']),
      implemented: json['implemented'] as bool? ?? true,
      recommendedOptions: _map(json['recommended_options']),
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
      implemented: json['implemented'] as bool? ?? true,
    );
  }
}

class MigrationCatalog {
  const MigrationCatalog({required this.systems, required this.entities});

  final List<MigrationSystem> systems;
  final List<MigrationEntitySpec> entities;

  factory MigrationCatalog.fromJson(Map<String, Object?> json) {
    return MigrationCatalog(
      systems: [
        for (final item in _list(json['systems']))
          MigrationSystem.fromJson(item),
      ],
      entities: [
        for (final item in _list(json['entities']))
          MigrationEntitySpec.fromJson(item),
      ],
    );
  }
}

class MigrationSource {
  const MigrationSource({
    required this.id,
    required this.name,
    required this.systemKey,
    required this.transportKind,
    required this.host,
    required this.port,
    required this.databaseName,
    required this.username,
    required this.hasPassword,
    required this.extraOptions,
    required this.detectedVersion,
    required this.lastCompatStatus,
    required this.lastCompatReport,
    required this.lastRunAt,
    required this.credentialsCleared,
    required this.isArchived,
  });

  final int id;
  final String name;
  final String systemKey;
  final String transportKind;
  final String host;
  final int? port;
  final String databaseName;
  final String username;
  final bool hasPassword;
  final Map<String, Object?> extraOptions;
  final String detectedVersion;
  final String lastCompatStatus; // unknown | compatible | incompatible
  final CompatibilityReport lastCompatReport;
  final DateTime? lastRunAt;
  final bool credentialsCleared;
  final bool isArchived;

  bool get isCompatible => lastCompatStatus == 'compatible';

  factory MigrationSource.fromJson(Map<String, Object?> json) {
    return MigrationSource(
      id: _int(json['id']),
      name: _str(json['name']),
      systemKey: _str(json['system_key']),
      transportKind: _str(json['transport_kind']),
      host: _str(json['host']),
      port: _intOrNull(json['port']),
      databaseName: _str(json['database_name']),
      username: _str(json['username']),
      hasPassword: json['has_password'] as bool? ?? false,
      extraOptions: _map(json['extra_options']),
      detectedVersion: _str(json['detected_version']),
      lastCompatStatus: _str(json['last_compat_status'], fallback: 'unknown'),
      lastCompatReport: CompatibilityReport.fromJson(
        _map(json['last_compat_report']),
      ),
      lastRunAt: _dateOrNull(json['last_run_at']),
      credentialsCleared: json['credentials_cleared'] as bool? ?? false,
      isArchived: json['is_archived'] as bool? ?? false,
    );
  }
}

/// Body for creating/updating a source. Only non-null fields are sent, so the
/// same draft works for create (all fields) and partial update.
class MigrationSourceDraft {
  const MigrationSourceDraft({
    this.name,
    this.systemKey,
    this.transportKind,
    this.host,
    this.port,
    this.databaseName,
    this.username,
    this.password,
    this.extraOptions,
    this.isArchived,
  });

  final String? name;
  final String? systemKey;
  final String? transportKind;
  final String? host;
  final int? port;
  final String? databaseName;
  final String? username;
  final String? password;
  final Map<String, Object?>? extraOptions;
  final bool? isArchived;

  Map<String, Object?> toJson() {
    final body = <String, Object?>{};
    if (name != null) body['name'] = name;
    if (systemKey != null) body['system_key'] = systemKey;
    if (transportKind != null) body['transport_kind'] = transportKind;
    if (host != null) body['host'] = host;
    if (port != null) body['port'] = port;
    if (databaseName != null) body['database_name'] = databaseName;
    if (username != null) body['username'] = username;
    if (password != null && password!.isNotEmpty) body['password'] = password;
    if (extraOptions != null) body['extra_options'] = extraOptions;
    if (isArchived != null) body['is_archived'] = isArchived;
    return body;
  }
}

class CompatibilityReport {
  const CompatibilityReport({
    required this.compatible,
    required this.detectedVersion,
    required this.missingTables,
    required this.missingColumns,
    required this.supportedEntities,
    required this.notes,
    required this.checked,
  });

  final bool compatible;
  final String? detectedVersion;
  final List<String> missingTables;
  final Map<String, List<String>> missingColumns;
  final List<String> supportedEntities;
  final List<String> notes;

  /// False when the report is an empty placeholder (never checked).
  final bool checked;

  factory CompatibilityReport.fromJson(Map<String, Object?> json) {
    final missingColumns = <String, List<String>>{};
    final rawColumns = json['missing_columns'];
    if (rawColumns is Map) {
      rawColumns.forEach((key, value) {
        missingColumns['$key'] = _stringList(value);
      });
    }
    return CompatibilityReport(
      compatible: json['compatible'] as bool? ?? false,
      detectedVersion: json['detected_version'] as String?,
      missingTables: _stringList(json['missing_tables']),
      missingColumns: missingColumns,
      supportedEntities: _stringList(json['supported_entities']),
      notes: _stringList(json['notes']),
      checked: json.isNotEmpty && json.containsKey('compatible'),
    );
  }
}

class MigrationConnectionTest {
  const MigrationConnectionTest({
    required this.ok,
    required this.tableCount,
    required this.tables,
  });

  final bool ok;
  final int tableCount;
  final List<String> tables;

  factory MigrationConnectionTest.fromJson(Map<String, Object?> json) {
    return MigrationConnectionTest(
      ok: json['ok'] as bool? ?? false,
      tableCount: _int(json['table_count']),
      tables: _stringList(json['tables']),
    );
  }
}

/// A SQL Server instance found on the LAN via the discovery broadcast. This is
/// the result of a *discovery* probe only — no credentials were sent. The
/// operator picks the client's POS box from these, which prefills host/port.
class DiscoveredServer {
  const DiscoveredServer({
    required this.address,
    required this.serverName,
    required this.instanceName,
    required this.version,
    required this.tcpPort,
  });

  final String address;
  final String serverName;
  final String instanceName;
  final String version;
  final int? tcpPort;

  /// "POSPC\\SQLEXPRESS" style label, falling back to the IP.
  String get displayName {
    final name = serverName.isNotEmpty ? serverName : address;
    return instanceName.isEmpty ? name : '$name\\$instanceName';
  }

  factory DiscoveredServer.fromJson(Map<String, Object?> json) {
    return DiscoveredServer(
      address: _str(json['address']),
      serverName: _str(json['server_name']),
      instanceName: _str(json['instance_name']),
      version: _str(json['version']),
      tcpPort: _intOrNull(json['tcp_port']),
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
