import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/employee.dart';
import '../../../data/repositories/employee_repository.dart';

class EmployeePayrollViewModel extends ChangeNotifier {
  EmployeePayrollViewModel(
    this._repository, {
    AnalyticsEngine? analyticsEngine,
    DateTime Function()? clock,
  }) : _analyticsEngine = analyticsEngine,
       _clock = clock ?? DateTime.now {
    loadEmployees();
    loadPayrollRuns();
    loadLoans();
  }

  final EmployeeRepository _repository;
  final AnalyticsEngine? _analyticsEngine;
  final DateTime Function() _clock;

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
  bool _monthDraftFoundNoPlans = false;
  bool _hasMoreEmployees = true;
  bool _hasMorePayrollRuns = true;
  bool _hasMoreLoans = true;
  int _nextEmployeePage = 1;
  int _nextPayrollPage = 1;
  int _nextLoanPage = 1;

  List<Employee> get employees => List.unmodifiable(_employees);

  /// The loaded employee with this id, if any.
  Employee? employeeById(int id) {
    for (final employee in _employees) {
      if (employee.id == id) {
        return employee;
      }
    }
    return null;
  }

  /// Reads one employee again — their account balance moves with every entry
  /// and every paid run — and puts the fresh copy in the list.
  Future<Employee?> refreshEmployee(int id) async {
    final result = await _repository.loadEmployee(id);
    switch (result) {
      case Ok<Employee>(value: final employee):
        _employees = [
          for (final existing in _employees)
            if (existing.id == employee.id) employee else existing,
        ];
        if (!_employees.any((existing) => existing.id == employee.id)) {
          _employees = [employee, ..._employees];
        }
        notifyListeners();
        return employee;
      case Error<Employee>():
        return null;
    }
  }

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

  /// The last "prepare this month" came back with nothing to draft: no
  /// employee has a salary plan in effect for the month. Not a failure — the
  /// server answered — so it is told apart from [hasSaveError].
  bool get monthDraftFoundNoPlans => _monthDraftFoundNoPlans;
  bool get hasMoreEmployees => _hasMoreEmployees;
  bool get hasMorePayrollRuns => _hasMorePayrollRuns;
  bool get hasMoreLoans => _hasMoreLoans;

  /// The month the payroll card is about: the calendar month the shop is in.
  /// The card's title, [currentMonthRun] and [draftMonthlyPayrollRun] all read
  /// it, so the month a manager is shown is the month that gets drafted.
  ({DateTime start, DateTime end}) get currentMonthPeriod {
    final now = _clock();
    return (
      start: DateTime(now.year, now.month),
      end: DateTime(now.year, now.month + 1, 0),
    );
  }

  /// The latest non-void payroll run whose period overlaps the current month.
  PayrollRun? get currentMonthRun {
    final (start: monthStart, end: monthEnd) = currentMonthPeriod;
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

  /// Why the last employee create was refused — the form names an opening
  /// balance the server turned down rather than showing a generic failure.
  Exception? get lastCreateError => _lastCreateError;
  Exception? _lastCreateError;

  Future<bool> createEmployee(EmployeeDraft draft) async {
    _lastCreateError = null;
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
        case Error<Employee>(:final exception):
          _lastCreateError = exception;
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

  /// Drafts the payroll run for [currentMonthPeriod] — the month on the card.
  ///
  /// It used to send no period, and the server then drafts the PREVIOUS month
  /// (right for its own task on the 1st, wrong for a card titled with this
  /// month). On 2026-09-30 a manager pressed it seven times: August had no
  /// salary plans, so each press came back empty and was shown as a failed
  /// save.
  Future<PayrollRun?> draftMonthlyPayrollRun() async {
    _isSaving = true;
    _hasSaveError = false;
    _monthDraftFoundNoPlans = false;
    notifyListeners();

    final (start: periodStart, end: periodEnd) = currentMonthPeriod;
    PayrollRun? run;
    final result = await _repository.draftMonthlyPayrollRun(
      periodStart: periodStart,
      periodEnd: periodEnd,
    );
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
        } else {
          _monthDraftFoundNoPlans = true;
        }
      case Error<PayrollDraftResult>():
        _hasSaveError = true;
    }

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

  /// Approves [loan] and records where its money came from. Returns null on
  /// success, or the refusal — the approval dialog says it back.
  Future<Exception?> approveLoan(
    EmployeeLoan loan, {
    LoanDisbursement disbursement = LoanDisbursement.cashBox,
  }) async {
    Exception? failure;
    await _updateLoan(loan, () async {
      final result = await _repository.approveEmployeeLoan(
        loan.id,
        disbursement: disbursement,
      );
      if (result case Error<EmployeeLoan>(:final exception)) {
        failure = exception;
      }
      return result;
    }, eventName: 'employees.management.loan.approved');
    return failure;
  }

  Future<bool> rejectLoan(EmployeeLoan loan) {
    return _updateLoan(
      loan,
      () => _repository.rejectEmployeeLoan(loan.id),
      eventName: 'employees.management.loan.rejected',
    );
  }

  /// Lends [draft]'s employee money. With [handOver] the money leaves at
  /// once, from where it says; without it the loan waits for an approval.
  /// Returns null on success, or the refusal — the loan form says it back,
  /// so it is not also raised as the screen's own save error.
  Future<Exception?> giveLoan(
    EmployeeLoanDraft draft, {
    LoanDisbursement? handOver,
  }) async {
    _isSaving = true;
    notifyListeners();

    final result = handOver == null
        ? await _repository.createEmployeeLoan(draft)
        : await _repository.grantEmployeeLoan(draft, disbursement: handOver);
    Exception? failure;
    switch (result) {
      case Ok<EmployeeLoan>(value: final loan):
        _upsertLoan(loan);
        _track(
          handOver == null
              ? 'employees.management.loan.created'
              : 'employees.management.loan.granted',
          'employee_loan',
          loan.id,
          {'employee': loan.employeeId, 'status': loan.status.name},
        );
      case Error<EmployeeLoan>(:final exception):
        failure = exception;
    }

    _isSaving = false;
    notifyListeners();
    return failure;
  }

  /// [employeeId]'s loans, newest first: what a new loan is weighed against.
  /// Null when they could not be read.
  Future<List<EmployeeLoan>?> loansFor(int employeeId) async {
    final result = await _repository.loadEmployeeLoans(employeeId: employeeId);
    return switch (result) {
      Ok<EmployeeLoanPage>(value: final page) => page.loans,
      Error<EmployeeLoanPage>() => null,
    };
  }

  /// One page of employees matching [search], to choose whose loan it is.
  Future<Result<EmployeePage>> searchEmployees({
    String search = '',
    int page = 1,
  }) {
    return _repository.loadEmployees(search: search, page: page);
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
