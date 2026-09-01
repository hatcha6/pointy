// ZKTeco BioTime attendance integration models.

import 'employee.dart';

int _intFrom(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? '').toString()) ?? 0;
}

DateTime? _dateTimeFrom(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}

class AttendanceConfig {
  const AttendanceConfig({
    required this.baseUrl,
    required this.username,
    required this.hasPassword,
    required this.isEnabled,
    required this.workdays,
    required this.shiftStart,
    required this.shiftEnd,
    required this.graceMinutes,
    this.lastSyncedAt,
    this.lastSyncStatus = 'never',
    this.lastSyncError = '',
    this.syncedFrom,
    this.syncedThrough,
    this.isSyncing = false,
    this.syncProgressPunches = 0,
    this.syncStartedAt,
  });

  final String baseUrl;
  final String username;
  final bool hasPassword;
  final bool isEnabled;

  /// Weekday numbers, Monday = 0 .. Sunday = 6.
  final List<int> workdays;

  /// "HH:MM:SS" times as returned by the backend.
  final String shiftStart;
  final String shiftEnd;
  final int graceMinutes;
  final DateTime? lastSyncedAt;
  final String lastSyncStatus;
  final String lastSyncError;

  /// The date range attendance has actually been imported for. A successful
  /// sync says nothing about WHICH dates it covered, and payroll can only cost
  /// absences inside this window.
  final DateTime? syncedFrom;
  final DateTime? syncedThrough;

  /// Live state of a sync running on a worker. The pull is not held open by the
  /// request that started it, so this is how the UI follows it.
  final bool isSyncing;
  final int syncProgressPunches;
  final DateTime? syncStartedAt;

  factory AttendanceConfig.fromJson(Map<String, Object?> json) {
    return AttendanceConfig(
      baseUrl: json['base_url']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      hasPassword: json['has_password'] == true,
      isEnabled: json['is_enabled'] == true,
      workdays: parseWorkdays(json['workdays']?.toString() ?? ''),
      shiftStart: json['shift_start']?.toString() ?? '09:00',
      shiftEnd: json['shift_end']?.toString() ?? '17:00',
      graceMinutes: _intFrom(json['grace_minutes']),
      lastSyncedAt: _dateTimeFrom(json['last_synced_at']),
      lastSyncStatus: json['last_sync_status']?.toString() ?? 'never',
      lastSyncError: json['last_sync_error']?.toString() ?? '',
      syncedFrom: _dateTimeFrom(json['synced_from']),
      syncedThrough: _dateTimeFrom(json['synced_through']),
      isSyncing: json['is_syncing'] == true,
      syncProgressPunches: _intFrom(json['sync_progress_punches']),
      syncStartedAt: _dateTimeFrom(json['sync_started_at']),
    );
  }

  static List<int> parseWorkdays(String value) {
    return value
        .split(',')
        .map((part) => int.tryParse(part.trim()))
        .whereType<int>()
        .where((day) => day >= 0 && day <= 6)
        .toList(growable: false);
  }
}

class AttendanceConfigDraft {
  const AttendanceConfigDraft({
    this.baseUrl,
    this.username,
    this.password,
    this.isEnabled,
    this.workdays,
    this.shiftStart,
    this.shiftEnd,
    this.graceMinutes,
  });

  final String? baseUrl;
  final String? username;

  /// Null or empty keeps the password stored on the backend.
  final String? password;
  final bool? isEnabled;
  final List<int>? workdays;
  final String? shiftStart;
  final String? shiftEnd;
  final int? graceMinutes;

  Map<String, Object?> toJson() {
    return {
      if (baseUrl != null) 'base_url': baseUrl,
      if (username != null) 'username': username,
      if (password != null && password!.isNotEmpty) 'password': password,
      if (isEnabled != null) 'is_enabled': isEnabled,
      if (workdays != null) 'workdays': workdays!.join(','),
      if (shiftStart != null) 'shift_start': shiftStart,
      if (shiftEnd != null) 'shift_end': shiftEnd,
      if (graceMinutes != null) 'grace_minutes': graceMinutes,
    };
  }
}

class AttendanceProfileLink {
  const AttendanceProfileLink({
    required this.id,
    required this.employeeId,
    required this.employeeName,
    required this.employeeNumber,
    required this.bioTimeEmpCode,
    required this.bioTimeFullName,
    required this.isTracked,
  });

  final int id;
  final int employeeId;
  final String employeeName;
  final String employeeNumber;
  final String bioTimeEmpCode;
  final String bioTimeFullName;
  final bool isTracked;

  factory AttendanceProfileLink.fromJson(Map<String, Object?> json) {
    return AttendanceProfileLink(
      id: _intFrom(json['id']),
      employeeId: _intFrom(json['employee']),
      employeeName: json['employee_name']?.toString() ?? '',
      employeeNumber: json['employee_number']?.toString() ?? '',
      bioTimeEmpCode: json['biotime_emp_code']?.toString() ?? '',
      bioTimeFullName: json['biotime_full_name']?.toString() ?? '',
      isTracked: json['is_tracked'] == true,
    );
  }
}

class AttendanceProfilePage {
  const AttendanceProfilePage({required this.profiles, required this.hasMore});

  final List<AttendanceProfileLink> profiles;
  final bool hasMore;

  factory AttendanceProfilePage.fromAny(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      final results = decoded['results'];
      return AttendanceProfilePage(
        profiles: results is List<Object?>
            ? results
                  .whereType<Map<String, Object?>>()
                  .map(AttendanceProfileLink.fromJson)
                  .toList(growable: false)
            : const [],
        hasMore: decoded['next'] != null,
      );
    }
    return const AttendanceProfilePage(profiles: [], hasMore: false);
  }
}

class AttendanceDayEntry {
  const AttendanceDayEntry({
    required this.id,
    required this.employeeId,
    required this.employeeName,
    required this.date,
    required this.status,
    required this.punchCount,
    required this.workedMinutes,
    required this.lateMinutes,
    required this.earlyLeaveMinutes,
    required this.overtimeMinutes,
    this.firstIn,
    this.lastOut,
  });

  final int id;
  final int employeeId;
  final String employeeName;
  final DateTime date;
  final String status;
  final DateTime? firstIn;
  final DateTime? lastOut;
  final int punchCount;
  final int workedMinutes;
  final int lateMinutes;
  final int earlyLeaveMinutes;
  final int overtimeMinutes;

  factory AttendanceDayEntry.fromJson(Map<String, Object?> json) {
    return AttendanceDayEntry(
      id: _intFrom(json['id']),
      employeeId: _intFrom(json['employee']),
      employeeName: json['employee_name']?.toString() ?? '',
      date: DateTime.tryParse(json['date']?.toString() ?? '') ?? DateTime(1970),
      status: json['status']?.toString() ?? '',
      firstIn: _dateTimeFrom(json['first_in']),
      lastOut: _dateTimeFrom(json['last_out']),
      punchCount: _intFrom(json['punch_count']),
      workedMinutes: _intFrom(json['worked_minutes']),
      lateMinutes: _intFrom(json['late_minutes']),
      earlyLeaveMinutes: _intFrom(json['early_leave_minutes']),
      overtimeMinutes: _intFrom(json['overtime_minutes']),
    );
  }
}

class AttendanceDayPage {
  const AttendanceDayPage({required this.days, required this.hasMore});

  final List<AttendanceDayEntry> days;
  final bool hasMore;

  factory AttendanceDayPage.fromAny(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      final results = decoded['results'];
      return AttendanceDayPage(
        days: results is List<Object?>
            ? results
                  .whereType<Map<String, Object?>>()
                  .map(AttendanceDayEntry.fromJson)
                  .toList(growable: false)
            : const [],
        hasMore: decoded['next'] != null,
      );
    }
    return const AttendanceDayPage(days: [], hasMore: false);
  }
}

class AttendanceSummary {
  const AttendanceSummary({
    required this.expectedDays,
    required this.presentDays,
    required this.absentDays,
    required this.workedMinutes,
    required this.lateMinutes,
    required this.earlyLeaveMinutes,
    required this.overtimeMinutes,
  });

  final int expectedDays;
  final int presentDays;
  final int absentDays;
  final int workedMinutes;
  final int lateMinutes;
  final int earlyLeaveMinutes;
  final int overtimeMinutes;

  factory AttendanceSummary.fromJson(Map<String, Object?> json) {
    return AttendanceSummary(
      expectedDays: _intFrom(json['expected_days']),
      presentDays: _intFrom(json['present_days']),
      absentDays: _intFrom(json['absent_days']),
      workedMinutes: _intFrom(json['worked_minutes']),
      lateMinutes: _intFrom(json['late_minutes']),
      earlyLeaveMinutes: _intFrom(json['early_leave_minutes']),
      overtimeMinutes: _intFrom(json['overtime_minutes']),
    );
  }
}

class UnmatchedBioTimePerson {
  const UnmatchedBioTimePerson({required this.empCode, required this.name});

  final String empCode;
  final String name;

  factory UnmatchedBioTimePerson.fromJson(Map<String, Object?> json) {
    return UnmatchedBioTimePerson(
      empCode: json['emp_code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
    );
  }
}

/// The result of costing a payroll run off attendance.
///
/// Carries the updated run plus the employees the period expected at work but
/// held no punches for at all. Arithmetically that is a full-period absence,
/// but it is just as often someone never enrolled on the terminal — so it is
/// shown as a warning rather than quietly deducting a month's pay.
class AttendanceApplyOutcome {
  const AttendanceApplyOutcome({
    required this.run,
    required this.employeesWithoutAttendance,
  });

  final PayrollRun run;
  final List<String> employeesWithoutAttendance;

  factory AttendanceApplyOutcome.fromJson(Map<String, Object?> json) {
    final attendance = json['attendance'];
    final missing = attendance is Map<String, Object?>
        ? attendance['lines_without_attendance']
        : null;
    return AttendanceApplyOutcome(
      run: PayrollRun.fromJson(json),
      employeesWithoutAttendance: missing is List<Object?>
          ? missing
                .whereType<Map<String, Object?>>()
                .map((row) => row['employee_name']?.toString() ?? '')
                .where((name) => name.isNotEmpty)
                .toList(growable: false)
          : const [],
    );
  }
}

/// What the server did with a sync request.
///
/// The pull runs on a worker, so starting one normally returns immediately and
/// the caller polls the connection for progress. Two exceptions: a shop with no
/// worker runs it inline and the finished [result] comes back with this
/// response, and a press landing on top of a sync already in flight is refused.
class AttendanceSyncStart {
  const AttendanceSyncStart({
    required this.queued,
    required this.alreadyRunning,
    this.result,
  });

  final bool queued;
  final bool alreadyRunning;

  /// Only present when the server ran the pull inline (no worker available).
  final AttendanceSyncResult? result;

  bool get isFinished => result != null;

  factory AttendanceSyncStart.fromJson(Map<String, Object?> json) {
    final queued = json['queued'] == true;
    final alreadyRunning = json['already_running'] == true;
    return AttendanceSyncStart(
      queued: queued,
      alreadyRunning: alreadyRunning,
      result: (queued || alreadyRunning)
          ? null
          : AttendanceSyncResult.fromJson(json),
    );
  }
}

class AttendanceSyncResult {
  const AttendanceSyncResult({
    required this.matchedEmployees,
    required this.unmatchedBioTime,
    required this.punchesImported,
    required this.daysRebuilt,
  });

  final int matchedEmployees;
  final List<UnmatchedBioTimePerson> unmatchedBioTime;
  final int punchesImported;
  final int daysRebuilt;

  factory AttendanceSyncResult.fromJson(Map<String, Object?> json) {
    final unmatched = json['unmatched_biotime'];
    return AttendanceSyncResult(
      matchedEmployees: _intFrom(json['matched_employees']),
      unmatchedBioTime: unmatched is List<Object?>
          ? unmatched
                .whereType<Map<String, Object?>>()
                .map(UnmatchedBioTimePerson.fromJson)
                .toList(growable: false)
          : const [],
      punchesImported: _intFrom(json['punches_imported']),
      daysRebuilt: _intFrom(json['days_rebuilt']),
    );
  }
}
