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

  Future<Result<PayrollRun>> loadPayrollRun(int id) {
    return Result.guard(() => _service.fetchPayrollRun(id));
  }

  Future<Result<PayrollRun>> createPayrollRun(PayrollRunDraft draft) {
    return Result.guard(() => _service.createPayrollRun(draft));
  }

  Future<Result<PayrollRun>> updatePayrollLineAdjustments(
    int payrollRunId,
    int payrollLineId,
    PayrollLineAdjustmentDraft draft,
  ) {
    return Result.guard(
      () => _service.updatePayrollLineAdjustments(
        payrollRunId,
        payrollLineId,
        draft,
      ),
    );
  }

  Future<Result<PayrollRun>> createPayrollBulkAdjustment(
    int payrollRunId,
    PayrollBulkAdjustmentDraft draft,
  ) {
    return Result.guard(
      () => _service.createPayrollBulkAdjustment(payrollRunId, draft),
    );
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

  Future<Result<EmployeeLoanPage>> loadEmployeeLoans({
    int page = 1,
    String status = '',
  }) {
    return Result.guard(
      () => _service.fetchEmployeeLoans(page: page, status: status),
    );
  }

  Future<Result<MyEmployeeLoans>> loadMyEmployeeLoans() {
    return Result.guard(() => _service.fetchMyEmployeeLoans());
  }

  Future<Result<EmployeeLoan>> requestEmployeeLoan(
    EmployeeLoanRequestDraft draft,
  ) {
    return Result.guard(() => _service.requestEmployeeLoan(draft));
  }

  Future<Result<EmployeeLoan>> approveEmployeeLoan(
    int id, {
    String reviewNotes = '',
  }) {
    return Result.guard(
      () => _service.approveEmployeeLoan(id, reviewNotes: reviewNotes),
    );
  }

  Future<Result<EmployeeLoan>> rejectEmployeeLoan(
    int id, {
    String reviewNotes = '',
  }) {
    return Result.guard(
      () => _service.rejectEmployeeLoan(id, reviewNotes: reviewNotes),
    );
  }
}
