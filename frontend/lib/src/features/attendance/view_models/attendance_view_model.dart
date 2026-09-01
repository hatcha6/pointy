import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/error_messages.dart';
import '../../../core/result.dart';
import '../../../data/models/attendance.dart';
import '../../../data/repositories/attendance_repository.dart';

/// Drives both the BioTime settings page and the attendance review tab.
class AttendanceViewModel extends ChangeNotifier {
  AttendanceViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine;

  final AttendanceRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  AttendanceConfig? _config;
  List<AttendanceProfileLink> _profiles = const [];
  List<AttendanceDayEntry> _days = const [];
  AttendanceSummary? _summary;
  AttendanceSyncResult? _lastSyncResult;
  int? _testedEmployeeCount;
  String? _lastApplyFailure;
  String? _syncStartFailure;

  /// How often, and for how long, a running sync is polled. A backfill against
  /// a real server was measured at ~150s for 20k punches, and a device with
  /// more history takes proportionally longer, so the ceiling is generous.
  @visibleForTesting
  static Duration syncPollInterval = const Duration(seconds: 2);
  @visibleForTesting
  static Duration syncPollTimeout = const Duration(minutes: 30);

  bool _isLoading = false;
  bool _isMutating = false;
  bool _isSyncing = false;
  bool _hasLoadError = false;
  bool _hasMutationError = false;

  AttendanceConfig? get config => _config;
  List<AttendanceProfileLink> get profiles => _profiles;
  List<AttendanceDayEntry> get days => _days;
  AttendanceSummary? get summary => _summary;
  AttendanceSyncResult? get lastSyncResult => _lastSyncResult;
  int? get testedEmployeeCount => _testedEmployeeCount;

  /// The backend's own sentence for the last failed payroll apply, when it gave
  /// one (e.g. the period lies outside the imported attendance window).
  String? get lastApplyFailure => _lastApplyFailure;

  /// Why the server refused to start a sync (e.g. one is already running).
  String? get syncStartFailure => _syncStartFailure;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get isSyncing => _isSyncing;
  bool get hasLoadError => _hasLoadError;
  bool get hasMutationError => _hasMutationError;
  bool get isEnabled => _config?.isEnabled ?? false;

  /// Loads only the connection config (no profile fetch/creation) so other
  /// screens can cheaply check whether BioTime is set up before showing
  /// attendance-driven actions. No-op once the config is already loaded.
  Future<void> ensureConfigLoaded() async {
    if (_config != null) {
      return;
    }
    final result = await _repository.loadConfig();
    if (result is Ok<AttendanceConfig>) {
      _config = result.value;
      notifyListeners();
    }
  }

  Future<void> loadSettings() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final configResult = await _repository.loadConfig();
    switch (configResult) {
      case Ok<AttendanceConfig>():
        _config = configResult.value;
      case Error<AttendanceConfig>():
        _hasLoadError = true;
    }
    if (!_hasLoadError) {
      await _repository.ensureProfiles();
      await _loadAllProfiles();
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> _loadAllProfiles() async {
    final loaded = <AttendanceProfileLink>[];
    var page = 1;
    while (true) {
      final result = await _repository.loadProfiles(page: page);
      switch (result) {
        case Ok<AttendanceProfilePage>():
          loaded.addAll(result.value.profiles);
          if (!result.value.hasMore) {
            _profiles = loaded;
            return;
          }
          page += 1;
        case Error<AttendanceProfilePage>():
          _hasLoadError = true;
          return;
      }
    }
  }

  Future<bool> saveConfig(AttendanceConfigDraft draft) async {
    return await _mutate(() async {
          final result = await _repository.updateConfig(draft);
          switch (result) {
            case Ok<AttendanceConfig>():
              _config = result.value;
              trackAuditEvent(
                _analyticsEngine,
                name: 'attendance.connection.updated',
                entityType: 'biotime_connection',
                entityId: 1,
                attributes: {'is_enabled': result.value.isEnabled},
              );
              return true;
            case Error<AttendanceConfig>():
              _hasMutationError = true;
              return false;
          }
        }) ??
        false;
  }

  Future<int?> testConnection() async {
    _testedEmployeeCount = null;
    return _mutate(() async {
      final result = await _repository.testConnection();
      switch (result) {
        case Ok<int>():
          _testedEmployeeCount = result.value;
          return result.value;
        case Error<int>():
          _hasMutationError = true;
          return null;
      }
    });
  }

  /// Starts a sync and follows it to completion.
  ///
  /// The pull runs on a worker and can take minutes on a device with years of
  /// history, so this returns only once the server stops reporting a run in
  /// progress. Progress is published through [config] as it polls, which is
  /// what lets the settings screen show a backfill advancing instead of an
  /// idle spinner.
  Future<AttendanceSyncResult?> sync() async {
    if (_isSyncing) {
      return null;
    }
    _isSyncing = true;
    _hasMutationError = false;
    _syncStartFailure = null;
    notifyListeners();

    AttendanceSyncResult? syncResult;
    final result = await _repository.sync();
    switch (result) {
      case Ok<AttendanceSyncStart>():
        final start = result.value;
        if (start.isFinished) {
          // No worker took it; the server ran the pull inline and it is done.
          syncResult = start.result;
        } else {
          await _awaitRunningSync();
        }
      case Error<AttendanceSyncStart>():
        _hasMutationError = true;
        _syncStartFailure = backendDetailFor(result.exception);
    }
    if (syncResult != null) {
      _lastSyncResult = syncResult;
      trackAuditEvent(
        _analyticsEngine,
        name: 'attendance.sync.requested',
        entityType: 'biotime_connection',
        entityId: 1,
        metrics: {
          'punches_imported': syncResult.punchesImported,
          'matched_employees': syncResult.matchedEmployees,
        },
      );
    }

    // Refresh config (sync status fields) and mapping snapshots.
    final configResult = await _repository.loadConfig();
    if (configResult case Ok<AttendanceConfig>()) {
      _config = configResult.value;
      if (_config!.lastSyncStatus == 'error' &&
          _config!.lastSyncError.isNotEmpty) {
        _hasMutationError = true;
      }
    }
    await _loadAllProfiles();

    _isSyncing = false;
    notifyListeners();
    return syncResult;
  }

  /// Polls the connection until the server stops reporting a sync in progress.
  ///
  /// Bounded: a worker that dies without clearing the flag would otherwise poll
  /// forever. The server's own heartbeat staleness check frees the lock for the
  /// next attempt, so giving up here only ends the watching, not the sync.
  Future<void> _awaitRunningSync() async {
    final deadline = DateTime.now().add(syncPollTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(syncPollInterval);
      final result = await _repository.loadConfig();
      if (result case Ok<AttendanceConfig>()) {
        _config = result.value;
        notifyListeners();
        if (!result.value.isSyncing) {
          return;
        }
      }
    }
  }

  Future<bool> updateProfile(
    AttendanceProfileLink profile, {
    String? bioTimeEmpCode,
    bool? isTracked,
  }) async {
    return await _mutate(() async {
          final result = await _repository.updateProfile(
            profile.id,
            bioTimeEmpCode: bioTimeEmpCode,
            isTracked: isTracked,
          );
          switch (result) {
            case Ok<AttendanceProfileLink>():
              _profiles = [
                for (final item in _profiles)
                  if (item.id == profile.id) result.value else item,
              ];
              return true;
            case Error<AttendanceProfileLink>():
              _hasMutationError = true;
              return false;
          }
        }) ??
        false;
  }

  Future<void> loadReview({
    required int employeeId,
    required DateTime dateFrom,
    required DateTime dateTo,
  }) async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final summaryResult = await _repository.loadSummary(
      employeeId: employeeId,
      dateFrom: dateFrom,
      dateTo: dateTo,
    );
    switch (summaryResult) {
      case Ok<AttendanceSummary>():
        _summary = summaryResult.value;
      case Error<AttendanceSummary>():
        _hasLoadError = true;
    }

    final loaded = <AttendanceDayEntry>[];
    var page = 1;
    while (!_hasLoadError) {
      final result = await _repository.loadDays(
        page: page,
        employeeId: employeeId,
        dateFrom: dateFrom,
        dateTo: dateTo,
      );
      switch (result) {
        case Ok<AttendanceDayPage>():
          loaded.addAll(result.value.days);
        case Error<AttendanceDayPage>():
          _hasLoadError = true;
      }
      if (_hasLoadError || !(result as Ok<AttendanceDayPage>).value.hasMore) {
        break;
      }
      page += 1;
    }
    if (!_hasLoadError) {
      _days = loaded;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<AttendanceApplyOutcome?> applyToPayrollRun(int payrollRunId) async {
    return _mutate(() async {
      _lastApplyFailure = null;
      final result = await _repository.applyAttendanceToPayrollRun(
        payrollRunId,
      );
      switch (result) {
        case Ok<AttendanceApplyOutcome>():
          trackAuditEvent(
            _analyticsEngine,
            name: 'attendance.payroll_run.apply_requested',
            entityType: 'payroll_run',
            entityId: payrollRunId,
          );
          return result.value;
        case Error<AttendanceApplyOutcome>():
          _hasMutationError = true;
          // The backend refuses periods it holds no attendance for and says
          // which window it does have; keep that sentence for the caller.
          _lastApplyFailure = backendDetailFor(result.exception);
          return null;
      }
    });
  }

  Future<T?> _mutate<T>(Future<T?> Function() operation) async {
    if (_isMutating) {
      return null;
    }
    _isMutating = true;
    _hasMutationError = false;
    notifyListeners();
    try {
      return await operation();
    } finally {
      _isMutating = false;
      notifyListeners();
    }
  }
}
