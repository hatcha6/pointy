import '../../core/result.dart';
import '../models/attendance.dart';
import '../models/employee.dart';
import '../services/pos_api_service.dart';

class AttendanceRepository {
  AttendanceRepository(this._service);

  final PosApiService _service;

  Future<Result<AttendanceConfig>> loadConfig() {
    return Result.guard(() => _service.fetchAttendanceConfig());
  }

  Future<Result<AttendanceConfig>> updateConfig(AttendanceConfigDraft draft) {
    return Result.guard(() => _service.updateAttendanceConfig(draft));
  }

  Future<Result<int>> testConnection() {
    return Result.guard(() => _service.testAttendanceConnection());
  }

  Future<Result<AttendanceSyncResult>> sync() {
    return Result.guard(() => _service.syncAttendance());
  }

  Future<Result<AttendanceProfilePage>> loadProfiles({int page = 1}) {
    return Result.guard(() => _service.fetchAttendanceProfiles(page: page));
  }

  Future<Result<void>> ensureProfiles() {
    return Result.guard(() => _service.ensureAttendanceProfiles());
  }

  Future<Result<AttendanceProfileLink>> updateProfile(
    int profileId, {
    String? bioTimeEmpCode,
    bool? isTracked,
  }) {
    return Result.guard(
      () => _service.updateAttendanceProfile(
        profileId,
        bioTimeEmpCode: bioTimeEmpCode,
        isTracked: isTracked,
      ),
    );
  }

  Future<Result<AttendanceDayPage>> loadDays({
    int page = 1,
    int? employeeId,
    DateTime? dateFrom,
    DateTime? dateTo,
  }) {
    return Result.guard(
      () => _service.fetchAttendanceDays(
        page: page,
        employeeId: employeeId,
        dateFrom: dateFrom,
        dateTo: dateTo,
      ),
    );
  }

  Future<Result<AttendanceSummary>> loadSummary({
    required int employeeId,
    required DateTime dateFrom,
    required DateTime dateTo,
  }) {
    return Result.guard(
      () => _service.fetchAttendanceSummary(
        employeeId: employeeId,
        dateFrom: dateFrom,
        dateTo: dateTo,
      ),
    );
  }

  Future<Result<PayrollRun>> applyAttendanceToPayrollRun(int payrollRunId) {
    return Result.guard(
      () => _service.applyAttendanceToPayrollRun(payrollRunId),
    );
  }
}
