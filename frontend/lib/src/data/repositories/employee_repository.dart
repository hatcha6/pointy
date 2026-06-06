import '../../core/result.dart';
import '../models/employee.dart';
import '../services/pos_api_service.dart';

class EmployeeRepository {
  EmployeeRepository(this._service);

  final PosApiService _service;

  Future<Result<EmployeePage>> loadEmployees({
    int page = 1,
    String search = '',
  }) {
    return Result.guard(
      () => _service.fetchEmployees(page: page, search: search),
    );
  }

  Future<Result<Employee>> createEmployee(EmployeeDraft draft) {
    return Result.guard(() => _service.createEmployee(draft));
  }

  Future<Result<CompensationPlan>> createCompensationPlan(
    CompensationPlanDraft draft,
  ) {
    return Result.guard(() => _service.createCompensationPlan(draft));
  }

  Future<Result<PayrollRunPage>> loadPayrollRuns({
    int page = 1,
    String search = '',
  }) {
    return Result.guard(
      () => _service.fetchPayrollRuns(page: page, search: search),
    );
  }

  Future<Result<PayrollRun>> createPayrollRun(PayrollRunDraft draft) {
    return Result.guard(() => _service.createPayrollRun(draft));
  }

  Future<Result<PayrollDraftResult>> draftMonthlyPayrollRun() {
    return Result.guard(() => _service.draftMonthlyPayrollRun());
  }

  Future<Result<PayrollRun>> approvePayrollRun(int id) {
    return Result.guard(() => _service.approvePayrollRun(id));
  }

  Future<Result<PayrollRun>> markPayrollRunPaid(int id) {
    return Result.guard(() => _service.markPayrollRunPaid(id));
  }
}
