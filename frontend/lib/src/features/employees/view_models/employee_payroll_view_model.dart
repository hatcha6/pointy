import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/employee.dart';
import '../../../data/repositories/employee_repository.dart';

class EmployeePayrollViewModel extends ChangeNotifier {
  EmployeePayrollViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine {
    loadEmployees();
    loadPayrollRuns();
  }

  final EmployeeRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  List<Employee> _employees = [];
  List<PayrollRun> _payrollRuns = [];
  bool _isLoadingEmployees = false;
  bool _isLoadingMoreEmployees = false;
  bool _isLoadingPayrollRuns = false;
  bool _isLoadingMorePayrollRuns = false;
  bool _isSaving = false;
  bool _hasEmployeeError = false;
  bool _hasPayrollError = false;
  bool _hasSaveError = false;
  bool _hasMoreEmployees = true;
  bool _hasMorePayrollRuns = true;
  int _nextEmployeePage = 1;
  int _nextPayrollPage = 1;

  List<Employee> get employees => List.unmodifiable(_employees);
  List<PayrollRun> get payrollRuns => List.unmodifiable(_payrollRuns);
  bool get isLoadingEmployees => _isLoadingEmployees;
  bool get isLoadingMoreEmployees => _isLoadingMoreEmployees;
  bool get isLoadingPayrollRuns => _isLoadingPayrollRuns;
  bool get isLoadingMorePayrollRuns => _isLoadingMorePayrollRuns;
  bool get isSaving => _isSaving;
  bool get hasEmployeeError => _hasEmployeeError;
  bool get hasPayrollError => _hasPayrollError;
  bool get hasSaveError => _hasSaveError;
  bool get hasMoreEmployees => _hasMoreEmployees;
  bool get hasMorePayrollRuns => _hasMorePayrollRuns;

  Future<void> loadEmployees() async {
    _isLoadingEmployees = true;
    _hasEmployeeError = false;
    _hasMoreEmployees = true;
    _nextEmployeePage = 1;
    notifyListeners();

    final result = await _repository.loadEmployees(page: _nextEmployeePage);
    switch (result) {
      case Ok<EmployeePage>(value: final page):
        _employees = page.employees;
        _hasMoreEmployees = page.hasMore;
        _nextEmployeePage = 2;
      case Error<EmployeePage>():
        _hasEmployeeError = true;
        _hasMoreEmployees = false;
    }
    _isLoadingEmployees = false;
    notifyListeners();
  }

  Future<void> loadMoreEmployees() async {
    if (_isLoadingEmployees || _isLoadingMoreEmployees || !_hasMoreEmployees) {
      return;
    }
    _isLoadingMoreEmployees = true;
    notifyListeners();

    final result = await _repository.loadEmployees(page: _nextEmployeePage);
    switch (result) {
      case Ok<EmployeePage>(value: final page):
        _employees = [..._employees, ...page.employees];
        _hasMoreEmployees = page.hasMore;
        _nextEmployeePage += 1;
      case Error<EmployeePage>():
        _hasEmployeeError = true;
        _hasMoreEmployees = false;
    }
    _isLoadingMoreEmployees = false;
    notifyListeners();
  }

  Future<void> loadPayrollRuns() async {
    _isLoadingPayrollRuns = true;
    _hasPayrollError = false;
    _hasMorePayrollRuns = true;
    _nextPayrollPage = 1;
    notifyListeners();

    final result = await _repository.loadPayrollRuns(page: _nextPayrollPage);
    switch (result) {
      case Ok<PayrollRunPage>(value: final page):
        _payrollRuns = page.runs;
        _hasMorePayrollRuns = page.hasMore;
        _nextPayrollPage = 2;
      case Error<PayrollRunPage>():
        _hasPayrollError = true;
        _hasMorePayrollRuns = false;
    }
    _isLoadingPayrollRuns = false;
    notifyListeners();
  }

  Future<void> loadMorePayrollRuns() async {
    if (_isLoadingPayrollRuns ||
        _isLoadingMorePayrollRuns ||
        !_hasMorePayrollRuns) {
      return;
    }
    _isLoadingMorePayrollRuns = true;
    notifyListeners();

    final result = await _repository.loadPayrollRuns(page: _nextPayrollPage);
    switch (result) {
      case Ok<PayrollRunPage>(value: final page):
        _payrollRuns = [..._payrollRuns, ...page.runs];
        _hasMorePayrollRuns = page.hasMore;
        _nextPayrollPage += 1;
      case Error<PayrollRunPage>():
        _hasPayrollError = true;
        _hasMorePayrollRuns = false;
    }
    _isLoadingMorePayrollRuns = false;
    notifyListeners();
  }

  Future<bool> createEmployee(EmployeeDraft draft) async {
    return _save(() async {
      final result = await _repository.createEmployee(draft);
      switch (result) {
        case Ok<Employee>(value: final employee):
          _employees = [employee, ..._employees];
          _track(
            'employees.management.employee.created',
            'employee',
            employee.id,
            {'status': employee.status.toJson()},
          );
          return true;
        case Error<Employee>():
          return false;
      }
    });
  }

  Future<bool> createCompensationPlan(CompensationPlanDraft draft) async {
    return _save(() async {
      final result = await _repository.createCompensationPlan(draft);
      switch (result) {
        case Ok<CompensationPlan>():
          await loadEmployees();
          _track(
            'employees.management.compensation_plan.created',
            'employee',
            draft.employeeId,
            {'pay_type': draft.payType.toJson()},
          );
          return true;
        case Error<CompensationPlan>():
          return false;
      }
    });
  }

  Future<bool> createPayrollRun(PayrollRunDraft draft) async {
    return _save(() async {
      final result = await _repository.createPayrollRun(draft);
      switch (result) {
        case Ok<PayrollRun>(value: final run):
          _payrollRuns = [run, ..._payrollRuns];
          _track(
            'employees.management.payroll_run.created',
            'payroll_run',
            run.id,
            {'line_count': draft.lines.length},
          );
          return true;
        case Error<PayrollRun>():
          return false;
      }
    });
  }

  Future<bool> approvePayrollRun(PayrollRun run) {
    return _updatePayrollRun(
      run,
      () => _repository.approvePayrollRun(run.id),
      eventName: 'employees.management.payroll_run.approved',
    );
  }

  Future<bool> markPayrollRunPaid(PayrollRun run) {
    return _updatePayrollRun(
      run,
      () => _repository.markPayrollRunPaid(run.id),
      eventName: 'employees.management.payroll_run.paid',
    );
  }

  Future<bool> _updatePayrollRun(
    PayrollRun run,
    Future<Result<PayrollRun>> Function() action, {
    required String eventName,
  }) {
    return _save(() async {
      final result = await action();
      switch (result) {
        case Ok<PayrollRun>(value: final updatedRun):
          _payrollRuns = [
            for (final existing in _payrollRuns)
              if (existing.id == updatedRun.id) updatedRun else existing,
          ];
          _track(eventName, 'payroll_run', updatedRun.id, {
            'previous_status': run.status.name,
            'new_status': updatedRun.status.name,
          });
          return true;
        case Error<PayrollRun>():
          return false;
      }
    });
  }

  Future<bool> _save(Future<bool> Function() action) async {
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final saved = await action();
    _hasSaveError = !saved;
    _isSaving = false;
    notifyListeners();
    return saved;
  }

  void _track(
    String name,
    String entityType,
    int entityId,
    Map<String, Object?> attributes,
  ) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: entityType,
      entityId: entityId,
      attributes: {...attributes, 'source': 'employee_payroll_management'},
    );
  }
}
