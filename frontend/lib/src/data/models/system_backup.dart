import 'dart:typed_data';

enum BackupOperation {
  backup,
  restore,
  unknown;

  factory BackupOperation.fromJson(Object? value) {
    return switch (value?.toString()) {
      'backup' => BackupOperation.backup,
      'restore' => BackupOperation.restore,
      _ => BackupOperation.unknown,
    };
  }

  String toJson() {
    return switch (this) {
      BackupOperation.backup => 'backup',
      BackupOperation.restore => 'restore',
      BackupOperation.unknown => 'unknown',
    };
  }
}

enum BackupJobStatus {
  queued,
  running,
  succeeded,
  failed,
  unknown;

  factory BackupJobStatus.fromJson(Object? value) {
    return switch (value?.toString()) {
      'queued' => BackupJobStatus.queued,
      'running' => BackupJobStatus.running,
      'succeeded' => BackupJobStatus.succeeded,
      'failed' => BackupJobStatus.failed,
      _ => BackupJobStatus.unknown,
    };
  }

  bool get isActive {
    return this == BackupJobStatus.queued || this == BackupJobStatus.running;
  }
}

class BackupDestination {
  const BackupDestination({
    required this.label,
    required this.path,
    required this.backupPath,
    required this.isAvailable,
    required this.isWritable,
    required this.totalBytes,
    required this.freeBytes,
  });

  final String label;
  final String path;
  final String backupPath;
  final bool isAvailable;
  final bool isWritable;
  final int totalBytes;
  final int freeBytes;

  bool get canUse => isAvailable && isWritable;

  factory BackupDestination.fromJson(Map<String, Object?> json) {
    return BackupDestination(
      label: json['label']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      backupPath: json['backup_path']?.toString() ?? '',
      isAvailable: _boolFromJson(json['is_available']),
      isWritable: _boolFromJson(json['is_writable']),
      totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
      freeBytes: (json['free_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

class BackupSchedule {
  const BackupSchedule({
    required this.enabled,
    required this.destinationPath,
    required this.scheduledTime,
    required this.retentionCount,
    this.nextScheduledAt,
  });

  final bool enabled;
  final String destinationPath;
  final String scheduledTime;
  final int retentionCount;
  final DateTime? nextScheduledAt;

  factory BackupSchedule.fromJson(Map<String, Object?> json) {
    return BackupSchedule(
      enabled: _boolFromJson(json['enabled']),
      destinationPath: json['destination_path']?.toString() ?? '',
      scheduledTime: json['scheduled_time']?.toString() ?? '02:00:00',
      retentionCount: (json['retention_count'] as num?)?.toInt() ?? 7,
      nextScheduledAt: _dateTimeFromJson(json['next_scheduled_at']),
    );
  }
}

class BackupScheduleDraft {
  const BackupScheduleDraft({
    required this.enabled,
    required this.destinationPath,
    required this.scheduledTime,
    required this.retentionCount,
  });

  final bool enabled;
  final String destinationPath;
  final String scheduledTime;
  final int retentionCount;

  Map<String, Object?> toJson() {
    return {
      'enabled': enabled,
      'destination_path': destinationPath,
      'scheduled_time': scheduledTime,
      'retention_count': retentionCount,
    };
  }
}

class SystemMaintenanceJob {
  const SystemMaintenanceJob({
    required this.id,
    required this.operation,
    required this.status,
    required this.progressPercent,
    required this.progressMessage,
    required this.destinationPath,
    required this.backupFileName,
    required this.archiveSizeBytes,
    required this.errorMessage,
    required this.metadata,
    required this.initiatedByUserId,
    required this.initiatedByUsername,
    this.createdAt,
    this.updatedAt,
    this.startedAt,
    this.completedAt,
  });

  final int id;
  final BackupOperation operation;
  final BackupJobStatus status;
  final int progressPercent;
  final String progressMessage;
  final String destinationPath;
  final String backupFileName;
  final int archiveSizeBytes;
  final String errorMessage;
  final Map<String, Object?> metadata;
  final int? initiatedByUserId;
  final String initiatedByUsername;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;

  bool get isActive => status.isActive;

  factory SystemMaintenanceJob.fromJson(Map<String, Object?> json) {
    return SystemMaintenanceJob(
      id: (json['id'] as num?)?.toInt() ?? 0,
      operation: BackupOperation.fromJson(json['operation']),
      status: BackupJobStatus.fromJson(json['status']),
      progressPercent: (json['progress_percent'] as num?)?.toInt() ?? 0,
      progressMessage: json['progress_message']?.toString() ?? '',
      destinationPath: json['destination_path']?.toString() ?? '',
      backupFileName: json['backup_file_name']?.toString() ?? '',
      archiveSizeBytes: (json['archive_size_bytes'] as num?)?.toInt() ?? 0,
      errorMessage: json['error_message']?.toString() ?? '',
      metadata: json['metadata'] is Map<String, Object?>
          ? json['metadata'] as Map<String, Object?>
          : const {},
      initiatedByUserId: (json['initiated_by_user_id'] as num?)?.toInt(),
      initiatedByUsername: json['initiated_by_username']?.toString() ?? '',
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
      startedAt: _dateTimeFromJson(json['started_at']),
      completedAt: _dateTimeFromJson(json['completed_at']),
    );
  }
}

/// Whether the shop actually has a way back, as opposed to whether the last
/// job reported success.
///
/// [latestVerifiedAt] moves only when an archive was written and then read back
/// intact. A backup that "succeeded" without being verified deliberately does
/// not count: that was the state a first shop sat in for weeks, with a green
/// history and nothing restorable behind it.
class BackupHealth {
  const BackupHealth({
    required this.enabled,
    required this.isStale,
    required this.staleAfterHours,
    required this.lastError,
    this.latestVerifiedAt,
    this.lastAttemptAt,
  });

  final bool enabled;
  final bool isStale;
  final int staleAfterHours;
  final String lastError;
  final DateTime? latestVerifiedAt;
  final DateTime? lastAttemptAt;

  /// Nothing has ever been verified on this install.
  bool get hasNeverVerified => latestVerifiedAt == null;

  static const BackupHealth unknown = BackupHealth(
    enabled: false,
    isStale: false,
    staleAfterHours: 48,
    lastError: '',
  );

  factory BackupHealth.fromJson(Map<String, Object?> json) {
    return BackupHealth(
      enabled: _boolFromJson(json['enabled']),
      isStale: _boolFromJson(json['is_stale']),
      staleAfterHours: (json['stale_after_hours'] as num?)?.toInt() ?? 48,
      lastError: json['last_error']?.toString() ?? '',
      latestVerifiedAt: _dateTimeFromJson(json['latest_verified_at']),
      lastAttemptAt: _dateTimeFromJson(json['last_attempt_at']),
    );
  }
}

class BackupOperationsStatus {
  const BackupOperationsStatus({
    required this.schedule,
    required this.health,
    this.activeJob,
    this.latestBackupJob,
    this.latestVerifiedBackupJob,
    this.latestRestoreJob,
  });

  final BackupSchedule schedule;
  final BackupHealth health;
  final SystemMaintenanceJob? activeJob;
  final SystemMaintenanceJob? latestBackupJob;
  final SystemMaintenanceJob? latestVerifiedBackupJob;
  final SystemMaintenanceJob? latestRestoreJob;

  factory BackupOperationsStatus.fromJson(Map<String, Object?> json) {
    return BackupOperationsStatus(
      schedule: BackupSchedule.fromJson(
        json['schedule'] as Map<String, Object?>? ?? const {},
      ),
      // Older backends do not send `health`; the screen then simply shows no
      // banner rather than claiming a problem it cannot see.
      health: json['health'] is Map<String, Object?>
          ? BackupHealth.fromJson(json['health'] as Map<String, Object?>)
          : BackupHealth.unknown,
      activeJob: _jobFromJson(json['active_job']),
      latestBackupJob: _jobFromJson(json['latest_backup_job']),
      latestVerifiedBackupJob: _jobFromJson(json['latest_verified_backup_job']),
      latestRestoreJob: _jobFromJson(json['latest_restore_job']),
    );
  }
}

class RestoreBackupUpload {
  const RestoreBackupUpload({
    required this.filename,
    required this.bytes,
    required this.contentType,
  });

  final String filename;
  final Uint8List bytes;
  final String contentType;
}

bool _boolFromJson(Object? value) {
  if (value is bool) {
    return value;
  }
  return value?.toString() == 'true';
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString())?.toLocal();
}

SystemMaintenanceJob? _jobFromJson(Object? value) {
  if (value is Map<String, Object?>) {
    return SystemMaintenanceJob.fromJson(value);
  }
  return null;
}
