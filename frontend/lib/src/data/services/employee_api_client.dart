import '../models/employee.dart';
import 'api_session.dart';

class EmployeeApiClient {
  const EmployeeApiClient(this._session);

  final PosApiSession _session;

  Future<EmployeePage> fetchEmployees({
    int page = 1,
    String search = '',
  }) async {
    final response = await _session.get(
      'employees/',
      query: {
        'page': '$page',
        if (search.trim().isNotEmpty) 'search': search.trim(),
      },
    );
    _session.ensureSuccess(response, 'Employees request failed with status');
    return EmployeePage.fromAny(_session.decodedBody(response));
  }

  /// One employee, with their account balance as it stands now.
  Future<Employee> fetchEmployee(int id) async {
    final response = await _session.get('employees/$id/');
    _session.throwApiException(response, 'Employee request failed with status');
    return Employee.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Employee> createEmployee(EmployeeDraft draft) async {
    final response = await _session.post('employees/', body: draft.toJson());
    // The body names what was refused — an opening balance the user may not
    // record, a date in the future — so the form can say which field.
    _session.throwApiException(response, 'Employee create failed with status');
    return Employee.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<CompensationPlan> createCompensationPlan(
    CompensationPlanDraft draft,
  ) async {
    final response = await _session.post(
      'compensation-plans/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Compensation plan create failed with status',
    );
    return CompensationPlan.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PayrollRunPage> fetchPayrollRuns({
    int page = 1,
    String search = '',
  }) async {
    final response = await _session.get(
      'payroll-runs/',
      query: {
        'page': '$page',
        if (search.trim().isNotEmpty) 'search': search.trim(),
      },
    );
    _session.ensureSuccess(response, 'Payroll request failed with status');
    return PayrollRunPage.fromAny(_session.decodedBody(response));
  }

  Future<PayrollRun> fetchPayrollRun(int id) async {
    final response = await _session.get('payroll-runs/$id/');
    _session.ensureSuccess(
      response,
      'Payroll detail request failed with status',
    );
    return PayrollRun.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PayrollRun> createPayrollRun(PayrollRunDraft draft) async {
    final response = await _session.post('payroll-runs/', body: draft.toJson());
    _session.ensureSuccess(response, 'Payroll create failed with status');
    return PayrollRun.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PayrollRun> updatePayrollLineAdjustments(
    int payrollRunId,
    int payrollLineId,
    PayrollLineAdjustmentDraft draft,
  ) async {
    final response = await _session.patch(
      'payroll-runs/$payrollRunId/lines/$payrollLineId/adjustments/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Payroll line adjustment update failed with status',
    );
    return PayrollRun.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PayrollRun> createPayrollBulkAdjustment(
    int payrollRunId,
    PayrollBulkAdjustmentDraft draft,
  ) async {
    final response = await _session.post(
      'payroll-runs/$payrollRunId/bulk-adjustments/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Payroll bulk adjustment create failed with status',
    );
    return PayrollRun.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PayrollDraftResult> draftMonthlyPayrollRun() async {
    final response = await _session.post('payroll-runs/draft-monthly/');
    _session.ensureSuccess(
      response,
      'Monthly payroll draft failed with status',
    );
    return PayrollDraftResult.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PayrollRun> approvePayrollRun(int id) async {
    final response = await _session.post('payroll-runs/$id/approve/');
    _session.ensureSuccess(response, 'Payroll approve failed with status');
    return PayrollRun.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PayrollRun> markPayrollRunPaid(int id) async {
    final response = await _session.post('payroll-runs/$id/mark-paid/');
    _session.ensureSuccess(response, 'Payroll paid failed with status');
    return PayrollRun.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<EmployeeLoanPage> fetchEmployeeLoans({
    int page = 1,
    String status = '',
  }) async {
    final response = await _session.get(
      'employee-loans/',
      query: {
        'page': '$page',
        if (status.trim().isNotEmpty) 'status': status.trim(),
      },
    );
    _session.ensureSuccess(
      response,
      'Employee loans request failed with status',
    );
    return EmployeeLoanPage.fromAny(_session.decodedBody(response));
  }

  Future<MyEmployeeLoans> fetchMyEmployeeLoans() async {
    final response = await _session.get('employee-loans/mine/');
    _session.ensureSuccess(
      response,
      'My employee loans request failed with status',
    );
    return MyEmployeeLoans.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<EmployeeLoan> requestEmployeeLoan(
    EmployeeLoanRequestDraft draft,
  ) async {
    final response = await _session.post(
      'employee-loans/request/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Employee loan request failed with status',
    );
    return EmployeeLoan.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Approves a loan and records where its money came from.
  Future<EmployeeLoan> approveEmployeeLoan(
    int id, {
    String reviewNotes = '',
    LoanDisbursement disbursement = LoanDisbursement.cashBox,
  }) async {
    final response = await _session.post(
      'employee-loans/$id/approve/',
      body: {
        if (reviewNotes.trim().isNotEmpty) 'review_notes': reviewNotes.trim(),
        ...disbursement.toJson(),
      },
    );
    // Kept whole: a refusal says why (no open drawer, no right to pay out of
    // one), and the approval dialog says it back.
    _session.throwApiException(
      response,
      'Employee loan approval failed with status',
    );
    return EmployeeLoan.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<EmployeeLoan> rejectEmployeeLoan(
    int id, {
    String reviewNotes = '',
  }) async {
    final response = await _session.post(
      'employee-loans/$id/reject/',
      body: {
        if (reviewNotes.trim().isNotEmpty) 'review_notes': reviewNotes.trim(),
      },
    );
    _session.ensureSuccess(
      response,
      'Employee loan rejection failed with status',
    );
    return EmployeeLoan.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
