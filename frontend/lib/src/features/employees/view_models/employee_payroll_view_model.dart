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
    loadLoans();
  }

  final EmployeeRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  List<Employee> _employees = [];
  List<PayrollRun> _payrollRuns = [];
  List<EmployeeLoan> _loans = [];
  bool _isLoadingEmployees = false;
  bool _isLoadingMoreEmployees = false;
  bool _isLoadingPayrollRuns = false;
  bool _isLoadingMorePayrollRuns = false;
  bool _isLoadingLoans = false;
  bool _isLoadingMoreLoans = false;
  bool _isSaving = false;
  bool _hasEmployeeError = false;
  bool _hasPayrollError = false;
  bool _hasLoanError = false;
  bool _hasSaveError = false;
  bool _hasMoreEmployees = true;
  bool _hasMorePayrollRuns = true;
  bool _hasMoreLoans = true;
  int _nextEmployeePage = 1;
  int _nextPayrollPage = 1;
  int _nextLoanPage = 1;

  List<Employee> get employees => List.unmodifiable(_employees);
  List<PayrollRun> get payrollRuns => List.unmodifiable(_payrollRuns);
  List<EmployeeLoan> get loans => List.unmodifiable(_loans);
  bool get isLoadingEmployees => _isLoadingEmployees;
  bool get isLoadingMoreEmployees => _isLoadingMoreEmployees;
  bool get isLoadingPayrollRuns => _isLoadingPayrollRuns;
  bool get isLoadingMorePayrollRuns => _isLoadingMorePayrollRuns;
  bool get isLoadingLoans => _isLoadingLoans;
  bool get isLoadingMoreLoans => _isLoadingMoreLoans;
  bool get isSaving => _isSaving;
  bool get hasEmployeeError => _hasEmployeeError;
  bool get hasPayrollError => _hasPayrollError;
  bool get hasLoanError => _hasLoanError;
  bool get hasSaveError => _hasSaveError;
  bool get hasMoreEmployees => _hasMoreEmployees;
  bool get hasMorePayrollRuns => _hasMorePayrollRuns;
  bool get hasMoreLoans => _hasMoreLoans;

  /// The latest non-void payroll run whose period overlaps the current month.
  PayrollRun? get currentMonthRun {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month);
    final monthEnd = DateTime(now.year, now.month + 1, 0);
    for (final run in _payrollRuns) {
      if (run.status == PayrollStatus.voided) {
        continue;
      }
      final start = run.periodStart;
      final end = run.periodEnd;
      if (start == null || end == null) {
        continue;
      }
      if (!end.isBefore(monthStart) && !start.isAfter(monthEnd)) {
        return run;
      }
    }
    return null;
  }

  List<EmployeeLoan> get pendingLoans =>
      List.unmodifiable(_loans.where((loan) => loan.status.canReview));

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

  Future<void> loadLoans() async {
    _isLoadingLoans = true;
    _hasLoanError = false;
    _hasMoreLoans = true;
    _nextLoanPage = 1;
    notifyListeners();

    final result = await _repository.loadEmployeeLoans(page: _nextLoanPage);
    switch (result) {
      case Ok<EmployeeLoanPage>(value: final page):
        _loans = page.loans;
        _hasMoreLoans = page.hasMore;
        _nextLoanPage = 2;
      case Error<EmployeeLoanPage>():
        _hasLoanError = true;
        _hasMoreLoans = false;
    }
    _isLoadingLoans = false;
    notifyListeners();
  }

  Future<void> loadMoreLoans() async {
    if (_isLoadingLoans || _isLoadingMoreLoans || !_hasMoreLoans) {
      return;
    }
    _isLoadingMoreLoans = true;
    notifyListeners();

    final result = await _repository.loadEmployeeLoans(page: _nextLoanPage);
    switch (result) {
      case Ok<EmployeeLoanPage>(value: final page):
        _loans = [..._loans, ...page.loans];
        _hasMoreLoans = page.hasMore;
        _nextLoanPage += 1;
      case Error<EmployeeLoanPage>():
        _hasLoanError = true;
        _hasMoreLoans = false;
    }
    _isLoadingMoreLoans = false;
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
            {
              'pay_type': draft.payType.toJson(),
              'salary_type': draft.salaryType.toJson(),
            },
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

  Future<PayrollRun?> draftMonthlyPayrollRun() async {
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    PayrollRun? run;
    final result = await _repository.draftMonthlyPayrollRun();
    switch (result) {
      case Ok<PayrollDraftResult>(value: final draft):
        run = draft.payrollRun;
        if (run != null) {
          _upsertPayrollRun(run);
          _track(
            'employees.management.payroll_run.monthly_drafted',
            'payroll_run',
            run.id,
            {'created': draft.created},
          );
        }
      case Error<PayrollDraftResult>():
        run = null;
    }

    _hasSaveError = run == null;
    _isSaving = false;
    notifyListeners();
    return run;
  }

  Future<bool> approvePayrollRun(PayrollRun run) {
    return _updatePayrollRun(
      run,
      () => _repository.approvePayrollRun(run.id),
      eventName: 'employees.management.payroll_run.approved',
    );
  }

  Future<bool> markPayrollRunPaid(PayrollRun run) {
    return _updatePayrollRun(run, () async {
      final result = await _repository.markPayrollRunPaid(run.id);
      if (result is Ok<PayrollRun>) {
        await loadLoans();
      }
      return result;
    }, eventName: 'employees.management.payroll_run.paid');
  }

  Future<bool> approveLoan(EmployeeLoan loan) {
    return _updateLoan(
      loan,
      () => _repository.approveEmployeeLoan(loan.id),
      eventName: 'employees.management.loan.approved',
    );
  }

  Future<bool> rejectLoan(EmployeeLoan loan) {
    return _updateLoan(
      loan,
      () => _repository.rejectEmployeeLoan(loan.id),
      eventName: 'employees.management.loan.rejected',
    );
  }

  Future<PayrollRun?> loadPayrollRunDetail(PayrollRun run) async {
    final result = await _repository.loadPayrollRun(run.id);
    switch (result) {
      case Ok<PayrollRun>(value: final detailedRun):
        _upsertPayrollRun(detailedRun);
        notifyListeners();
        return detailedRun;
      case Error<PayrollRun>():
        return null;
    }
  }

  Future<PayrollRun?> updatePayrollLineAdjustments(
    PayrollRun run,
    PayrollLine line,
    PayrollLineAdjustmentDraft draft,
  ) async {
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final result = await _repository.updatePayrollLineAdjustments(
      run.id,
      line.id,
      draft,
    );
    PayrollRun? updatedRun;
    switch (result) {
      case Ok<PayrollRun>(value: final savedRun):
        updatedRun = savedRun;
        _upsertPayrollRun(savedRun);
        _track(
          'employees.management.payroll_line.adjusted',
          'payroll_line',
          line.id,
          {'payroll_run': run.id, 'employee': line.employeeId},
        );
      case Error<PayrollRun>():
        _hasSaveError = true;
    }

    _isSaving = false;
    notifyListeners();
    return updatedRun;
  }

  Future<PayrollRun?> createPayrollBulkAdjustment(
    PayrollRun run,
    PayrollBulkAdjustmentDraft draft,
  ) async {
    if (draft.payrollLineIds.isEmpty) {
      _hasSaveError = true;
      notifyListeners();
      return null;
    }

    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final result = await _repository.createPayrollBulkAdjustment(run.id, draft);
    PayrollRun? updatedRun;
    switch (result) {
      case Ok<PayrollRun>(value: final savedRun):
        updatedRun = savedRun;
        _upsertPayrollRun(savedRun);
        _track(
          'employees.management.payroll_run.bulk_adjusted',
          'payroll_run',
          savedRun.id,
          {
            'line_count': draft.payrollLineIds.length,
            'direction': draft.type.direction,
            'adjustment_type': draft.type.adjustmentType,
            'amount': draft.amount,
          },
        );
      case Error<PayrollRun>():
        _hasSaveError = true;
    }

    _isSaving = false;
    notifyListeners();
    return updatedRun;
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
          _upsertPayrollRun(updatedRun);
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

  Future<bool> _updateLoan(
    EmployeeLoan loan,
    Future<Result<EmployeeLoan>> Function() action, {
    required String eventName,
  }) {
    return _save(() async {
      final result = await action();
      switch (result) {
        case Ok<EmployeeLoan>(value: final updatedLoan):
          _upsertLoan(updatedLoan);
          _track(eventName, 'employee_loan', updatedLoan.id, {
            'previous_status': loan.status.name,
            'new_status': updatedLoan.status.name,
            'employee': updatedLoan.employeeId,
          });
          return true;
        case Error<EmployeeLoan>():
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

  void _upsertPayrollRun(PayrollRun run) {
    final exists = _payrollRuns.any((existing) => existing.id == run.id);
    if (exists) {
      _payrollRuns = [
        for (final existing in _payrollRuns)
          if (existing.id == run.id) run else existing,
      ];
    } else {
      _payrollRuns = [run, ..._payrollRuns];
    }
  }

  void _upsertLoan(EmployeeLoan loan) {
    final exists = _loans.any((existing) => existing.id == loan.id);
    if (exists) {
      _loans = [
        for (final existing in _loans)
          if (existing.id == loan.id) loan else existing,
      ];
    } else {
      _loans = [loan, ..._loans];
    }
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
