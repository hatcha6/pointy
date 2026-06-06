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

  Future<Employee> createEmployee(EmployeeDraft draft) async {
    final response = await _session.post('employees/', body: draft.toJson());
    _session.ensureSuccess(response, 'Employee create failed with status');
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

  Future<PayrollRun> createPayrollRun(PayrollRunDraft draft) async {
    final response = await _session.post('payroll-runs/', body: draft.toJson());
    _session.ensureSuccess(response, 'Payroll create failed with status');
    return PayrollRun.fromJson(
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
}
