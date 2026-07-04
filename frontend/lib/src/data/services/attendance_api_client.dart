import '../models/attendance.dart';
import '../models/employee.dart';
import 'api_session.dart';

class AttendanceApiClient {
  const AttendanceApiClient(this._session);

  final PosApiSession _session;

  Future<AttendanceConfig> fetchConfig() async {
    final response = await _session.get('attendance/connection/');
    _session.ensureSuccess(
      response,
      'Attendance config request failed with status',
    );
    return AttendanceConfig.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<AttendanceConfig> updateConfig(AttendanceConfigDraft draft) async {
    final response = await _session.patch(
      'attendance/connection/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Attendance config update failed with status',
    );
    return AttendanceConfig.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<int> testConnection() async {
    final response = await _session.post('attendance/connection/test/');
    _session.ensureSuccess(
      response,
      'Attendance connection test failed with status',
    );
    final decoded = _session.decodedBody(response);
    if (decoded is Map<String, Object?>) {
      final count = decoded['employee_count'];
      if (count is num) {
        return count.toInt();
      }
    }
    return 0;
  }

  Future<AttendanceSyncResult> sync() async {
    final response = await _session.post('attendance/sync/');
    _session.ensureSuccess(response, 'Attendance sync failed with status');
    return AttendanceSyncResult.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<AttendanceProfilePage> fetchProfiles({int page = 1}) async {
    final response = await _session.get(
      'attendance/profiles/',
      query: {'page': '$page'},
    );
    _session.ensureSuccess(
      response,
      'Attendance profiles request failed with status',
    );
    return AttendanceProfilePage.fromAny(_session.decodedBody(response));
  }

  Future<void> ensureProfiles() async {
    final response = await _session.post('attendance/profiles/ensure/');
    _session.ensureSuccess(
      response,
      'Attendance profiles ensure failed with status',
    );
  }

  Future<AttendanceProfileLink> updateProfile(
    int profileId, {
    String? bioTimeEmpCode,
    bool? isTracked,
  }) async {
    final response = await _session.patch(
      'attendance/profiles/$profileId/',
      body: {if (bioTimeEmpCode != null) 'biotime_emp_code': bioTimeEmpCode, if (isTracked != null) 'is_tracked': isTracked},
    );
    _session.ensureSuccess(
      response,
      'Attendance profile update failed with status',
    );
    return AttendanceProfileLink.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<AttendanceDayPage> fetchDays({
    int page = 1,
    int? employeeId,
    DateTime? dateFrom,
    DateTime? dateTo,
  }) async {
    final response = await _session.get(
      'attendance/days/',
      query: {
        'page': '$page',
        if (employeeId != null) 'employee': '$employeeId',
        if (dateFrom != null) 'date_from': _dateParam(dateFrom),
        if (dateTo != null) 'date_to': _dateParam(dateTo),
      },
    );
    _session.ensureSuccess(
      response,
      'Attendance days request failed with status',
    );
    return AttendanceDayPage.fromAny(_session.decodedBody(response));
  }

  Future<AttendanceSummary> fetchSummary({
    required int employeeId,
    required DateTime dateFrom,
    required DateTime dateTo,
  }) async {
    final response = await _session.get(
      'attendance/days/summary/',
      query: {
        'employee': '$employeeId',
        'date_from': _dateParam(dateFrom),
        'date_to': _dateParam(dateTo),
      },
    );
    _session.ensureSuccess(
      response,
      'Attendance summary request failed with status',
    );
    return AttendanceSummary.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PayrollRun> applyAttendanceToPayrollRun(int payrollRunId) async {
    final response = await _session.post(
      'payroll-runs/$payrollRunId/apply-attendance/',
    );
    _session.ensureSuccess(
      response,
      'Payroll attendance apply failed with status',
    );
    return PayrollRun.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  String _dateParam(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }
}
