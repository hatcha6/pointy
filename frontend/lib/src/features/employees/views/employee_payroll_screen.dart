import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/employee.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/user_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../attendance/view_models/attendance_view_model.dart';
import '../../attendance/views/attendance_review_tab.dart';
import '../view_models/employee_payroll_view_model.dart';
import 'employee_account_screen.dart';
import 'employee_loan_review_actions.dart';
import 'employee_loan_row.dart';
import 'employee_loan_sheet.dart';
import 'employee_sheets.dart';
import 'payroll_labels.dart';
import 'payroll_month_card.dart';
import 'payroll_run_details_screen.dart';

/// Employees & payroll workspace. The payroll tab is task-first: a single
/// month card ([PayrollMonthCard]) walks the owner through prepare → approve
/// → pay, with pending loan requests surfaced underneath and history below.
class EmployeePayrollScreen extends StatelessWidget {
  const EmployeePayrollScreen({
    super.key,
    required this.viewModel,
    required this.attendanceViewModel,
    required this.userRepository,
    required this.capabilities,
    required this.navigation,
    this.contactRepository,
  });

  final EmployeePayrollViewModel viewModel;
  final AttendanceViewModel attendanceViewModel;
  final UserRepository userRepository;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;

  /// Carries the balance entries an employee's account shows. Without it the
  /// rows open nothing.
  final ContactRepository? contactRepository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.employees,
            navigation: navigation,
          ),
          appBar: PointyAppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.employeePayrollTitle),
            isLoading:
                viewModel.isLoadingEmployees ||
                viewModel.isLoadingPayrollRuns ||
                viewModel.isLoadingLoans,
            reserveLoadingSlot: false,
            actions: [
              EmployeePayrollGuard(
                capabilities: capabilities,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshEmployeePayrollTooltip,
                  onPressed: () {
                    viewModel.loadEmployees();
                    viewModel.loadPayrollRuns();
                    viewModel.loadLoans();
                  },
                  icon: const Icon(Icons.sync),
                ),
              ),
            ],
          ),
          body: EmployeePayrollGuard(
            capabilities: capabilities,
            child: _EmployeePayrollBody(
              viewModel: viewModel,
              attendanceViewModel: attendanceViewModel,
              userRepository: userRepository,
              capabilities: capabilities,
              contactRepository: contactRepository,
            ),
          ),
        );
      },
    );
  }
}

class _EmployeePayrollBody extends StatelessWidget {
  const _EmployeePayrollBody({
    required this.viewModel,
    required this.attendanceViewModel,
    required this.userRepository,
    required this.capabilities,
    this.contactRepository,
  });

  final EmployeePayrollViewModel viewModel;
  final AttendanceViewModel attendanceViewModel;
  final UserRepository userRepository;
  final AuthorizationCapabilities capabilities;
  final ContactRepository? contactRepository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final showAttendance = capabilities.canViewAttendance;

    return DefaultTabController(
      length: showAttendance ? 4 : 3,
      child: Padding(
        padding: spacing.pagePadding,
        child: AdaptiveMaxWidth(
          width: AppContentWidth.workspace,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (viewModel.hasSaveError) ...[
                PointyInlineMessage.error(
                  message: l10n.employeePayrollSaveError,
                  icon: Icons.warning_amber_outlined,
                ),
                SizedBox(height: spacing.sm),
              ],
              TabBar(
                tabs: [
                  Tab(text: l10n.payrollHomeTabLabel),
                  Tab(text: l10n.employeesTabLabel),
                  Tab(text: l10n.employeeLoansTabLabel),
                  if (showAttendance) Tab(text: l10n.attendanceTabLabel),
                ],
              ),
              SizedBox(height: spacing.sm),
              Expanded(
                child: TabBarView(
                  children: [
                    _PayrollHomeTab(
                      viewModel: viewModel,
                      attendanceViewModel: attendanceViewModel,
                      userRepository: userRepository,
                      capabilities: capabilities,
                    ),
                    _EmployeesTab(
                      viewModel: viewModel,
                      userRepository: userRepository,
                      capabilities: capabilities,
                      contactRepository: contactRepository,
                    ),
                    _LoansTab(viewModel: viewModel, capabilities: capabilities),
                    if (showAttendance)
                      AttendanceReviewTab(
                        viewModel: attendanceViewModel,
                        employees: viewModel.employees,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PayrollHomeTab extends StatelessWidget {
  const _PayrollHomeTab({
    required this.viewModel,
    required this.attendanceViewModel,
    required this.userRepository,
    required this.capabilities,
  });

  final EmployeePayrollViewModel viewModel;
  final AttendanceViewModel attendanceViewModel;
  final UserRepository userRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final pendingLoans = viewModel.pendingLoans;

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: spacing.xs),
        PayrollMonthCard(
          viewModel: viewModel,
          capabilities: capabilities,
          onOpenRun: (run) => _openRunDetails(context, run),
          onAddEmployee: () => showAddEmployeeFlow(
            context,
            viewModel: viewModel,
            userRepository: userRepository,
            allowOpeningBalance: capabilities.canManageEmployeeBalances,
          ),
          onSetSalary: (employee) => showCompensationPlanSheet(
            context,
            viewModel: viewModel,
            employee: employee,
          ),
          onShowEmployees: () => DefaultTabController.of(context).animateTo(1),
        ),
        if (pendingLoans.isNotEmpty && capabilities.canManageEmployeeLoans) ...[
          SizedBox(height: spacing.md),
          _PendingLoansCard(viewModel: viewModel, loans: pendingLoans),
        ],
        SizedBox(height: spacing.md),
        PointySectionHeader(
          title: l10n.payrollHistoryTitle,
          leading: const Icon(Icons.history_outlined),
          actions: [
            // The exception path — a leaver, a late hire, another period —
            // so it sits with the history, not on the month's task card.
            if (capabilities.canManagePayroll)
              TextButton.icon(
                key: const ValueKey('payroll_custom_run_button'),
                onPressed: viewModel.isSaving
                    ? null
                    : () => showCustomPayrollRunSheet(
                        context,
                        viewModel: viewModel,
                      ),
                icon: const Icon(Icons.tune_outlined, size: 18),
                label: Text(l10n.payrollOtherRunButton),
              ),
          ],
        ),
        SizedBox(height: spacing.sm),
      ],
    );

    return PointyDataList<PayrollRun>(
      header: header,
      items: viewModel.payrollRuns,
      onLoadMore: viewModel.loadMorePayrollRuns,
      hasMore: viewModel.hasMorePayrollRuns,
      isLoadingInitial: viewModel.isLoadingPayrollRuns,
      isLoadingMore: viewModel.isLoadingMorePayrollRuns,
      hasError: viewModel.hasPayrollError,
      errorBuilder: (context) => PointyErrorState(
        title: l10n.payrollRunsLoadError,
        icon: Icons.payments_outlined,
        action: OutlinedButton.icon(
          key: const ValueKey('payroll_runs_retry_button'),
          onPressed: viewModel.loadPayrollRuns,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryButton),
        ),
      ),
      emptyBuilder: (context) => PointyEmptyState(
        icon: Icons.payments_outlined,
        title: l10n.emptyPayrollRuns,
      ),
      padding: EdgeInsets.zero,
      framed: false,
      itemBuilder: (context, run) {
        return PointyDataRow(
          leading: CircleAvatar(child: Icon(payrollStatusIcon(run.status))),
          title: run.periodStart != null
              ? payrollMonthLabel(context, run.periodStart!)
              : run.runNumber,
          subtitle: '${run.runNumber} - ${payrollPeriodLabel(l10n, run)}',
          onTap: () => _openRunDetails(context, run),
          trailing: Text(
            formatMoney(run.netTotal),
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          badges: [
            PointyStatusPill(
              label: payrollStatusLabel(l10n, run.status),
              icon: payrollStatusIcon(run.status),
              color: payrollStatusColor(context, run.status),
            ),
            PointyStatusPill(
              label: l10n.payrollLineCount(run.lineCount),
              icon: Icons.groups_outlined,
            ),
          ],
        );
      },
    );
  }

  void _openRunDetails(BuildContext context, PayrollRun run) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PayrollRunDetailsScreen(
          viewModel: viewModel,
          attendanceViewModel: attendanceViewModel,
          capabilities: capabilities,
          initialRun: run,
        ),
      ),
    );
  }
}

class _PendingLoansCard extends StatelessWidget {
  const _PendingLoansCard({required this.viewModel, required this.loans});

  static const int _maxVisible = 3;

  final EmployeePayrollViewModel viewModel;
  final List<EmployeeLoan> loans;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final visible = loans.take(_maxVisible).toList(growable: false);

    return Card(
      key: const ValueKey('payroll_pending_loans_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: spacing.compactPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.notifications_active_outlined,
                  color: colors.warning,
                ),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: Text(
                    l10n.pendingLoanRequestsTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                PointyStatusPill(
                  label: '${loans.length}',
                  color: colors.warning,
                ),
              ],
            ),
            SizedBox(height: spacing.sm),
            for (final loan in visible) ...[
              _PendingLoanRow(viewModel: viewModel, loan: loan),
              if (loan != visible.last) Divider(height: spacing.md),
            ],
            if (loans.length > _maxVisible) ...[
              SizedBox(height: spacing.xs),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: () =>
                      DefaultTabController.of(context).animateTo(2),
                  child: Text(l10n.showAllLoansButton),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PendingLoanRow extends StatelessWidget {
  const _PendingLoanRow({required this.viewModel, required this.loan});

  final EmployeePayrollViewModel viewModel;
  final EmployeeLoan loan;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final subtitleParts = [
      l10n.employeeLoanAmountDetail(formatMoney(loan.amount)),
      l10n.employeeLoanMonthlyDeductionDetail(
        formatMoney(loan.monthlyDeduction),
      ),
      if (loan.purpose.trim().isNotEmpty) loan.purpose.trim(),
    ];

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                loan.employeeName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitleParts.join(' - '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.mutedInk,
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: spacing.sm),
        EmployeeLoanReviewActions(
          keyPrefix: 'pending_loan',
          loan: loan,
          isSaving: viewModel.isSaving,
          onApprove: (disbursement) =>
              viewModel.approveLoan(loan, disbursement: disbursement),
          onReject: () => viewModel.rejectLoan(loan),
        ),
      ],
    );
  }
}

class _EmployeesTab extends StatelessWidget {
  const _EmployeesTab({
    required this.viewModel,
    required this.userRepository,
    required this.capabilities,
    this.contactRepository,
  });

  final EmployeePayrollViewModel viewModel;
  final UserRepository userRepository;
  final AuthorizationCapabilities capabilities;
  final ContactRepository? contactRepository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (capabilities.canManageEmployees) ...[
          SizedBox(height: spacing.xs),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              key: const ValueKey('add_employee_button'),
              onPressed: viewModel.isSaving
                  ? null
                  : () => showAddEmployeeFlow(
                      context,
                      viewModel: viewModel,
                      userRepository: userRepository,
                      allowOpeningBalance:
                          capabilities.canManageEmployeeBalances,
                    ),
              icon: const Icon(Icons.person_add_alt_1),
              label: Text(l10n.addEmployeeButton),
            ),
          ),
          SizedBox(height: spacing.sm),
        ],
        Expanded(
          child: PointyDataList<Employee>(
            items: viewModel.employees,
            onLoadMore: viewModel.loadMoreEmployees,
            hasMore: viewModel.hasMoreEmployees,
            isLoadingInitial: viewModel.isLoadingEmployees,
            isLoadingMore: viewModel.isLoadingMoreEmployees,
            hasError: viewModel.hasEmployeeError,
            errorBuilder: (context) => PointyErrorState(
              title: l10n.employeesLoadError,
              icon: Icons.badge_outlined,
              action: OutlinedButton.icon(
                key: const ValueKey('employees_retry_button'),
                onPressed: viewModel.loadEmployees,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.retryButton),
              ),
            ),
            emptyBuilder: (context) => PointyEmptyState(
              icon: Icons.badge_outlined,
              title: l10n.emptyEmployees,
            ),
            padding: EdgeInsets.zero,
            framed: false,
            itemBuilder: (context, employee) {
              final plan = employee.activeCompensationPlan;
              final balance = employee.accountBalance;
              final repository = contactRepository;
              return PointyDataRow(
                key: ValueKey('employee_row_${employee.id}'),
                onTap: repository == null
                    ? null
                    : () => _openAccount(context, employee, repository),
                leading: CircleAvatar(
                  child: Icon(
                    employee.hasSystemAccess
                        ? Icons.admin_panel_settings_outlined
                        : Icons.badge_outlined,
                  ),
                ),
                title: employee.fullName,
                subtitle: _employeeSubtitle(l10n, employee),
                badges: [
                  PointyStatusPill(
                    label: employeeStatusLabel(l10n, employee.status),
                    icon: Icons.circle_outlined,
                    color: employeeStatusColor(context, employee.status),
                  ),
                  if (plan != null)
                    PointyStatusPill(
                      label: compensationPlanLabel(l10n, plan),
                      icon: Icons.payments_outlined,
                    )
                  else
                    PointyStatusPill(
                      label: l10n.employeeNoPlanWarning,
                      icon: Icons.warning_amber_outlined,
                      color: context.pointyColors.warning,
                    ),
                  if (employee.hasSystemAccess)
                    PointyStatusPill(
                      label: l10n.employeeSystemAccessLabel(
                        employee.userUsername,
                      ),
                      icon: Icons.verified_user_outlined,
                    ),
                  if (balance != null && !balance.isEmpty)
                    PointyStatusPill(
                      label: l10n.employeeAccountBalanceValue(
                        formatMoney(balance.owedByEmployee),
                        formatMoney(balance.owedToEmployee),
                      ),
                      icon: Icons.account_balance_wallet_outlined,
                      color: context.pointyColors.warning,
                    ),
                ],
                actions: [
                  if (capabilities.canManageEmployees)
                    TextButton.icon(
                      key: ValueKey('employee_plan_button_${employee.id}'),
                      onPressed: viewModel.isSaving
                          ? null
                          : () => showCompensationPlanSheet(
                              context,
                              viewModel: viewModel,
                              employee: employee,
                            ),
                      icon: const Icon(Icons.price_change_outlined),
                      label: Text(l10n.employeeCompensationButton),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  String _employeeSubtitle(AppLocalizations l10n, Employee employee) {
    final parts = [
      if (employee.employeeNumber.isNotEmpty) employee.employeeNumber,
      if (employee.jobTitle.isNotEmpty) employee.jobTitle,
      if (employee.department.isNotEmpty) employee.department,
    ];
    return parts.isEmpty ? l10n.employeeNoDetails : parts.join(' - ');
  }

  void _openAccount(
    BuildContext context,
    Employee employee,
    ContactRepository repository,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EmployeeAccountScreen(
          viewModel: viewModel,
          employee: employee,
          contactRepository: repository,
          capabilities: capabilities,
        ),
      ),
    );
  }
}

class _LoansTab extends StatelessWidget {
  const _LoansTab({required this.viewModel, required this.capabilities});

  final EmployeePayrollViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final list = PointyDataList<EmployeeLoan>(
      items: viewModel.loans,
      onLoadMore: viewModel.loadMoreLoans,
      hasMore: viewModel.hasMoreLoans,
      isLoadingInitial: viewModel.isLoadingLoans,
      isLoadingMore: viewModel.isLoadingMoreLoans,
      hasError: viewModel.hasLoanError,
      errorBuilder: (context) => PointyErrorState(
        title: l10n.employeeLoansLoadError,
        icon: Icons.account_balance_wallet_outlined,
        action: OutlinedButton.icon(
          key: const ValueKey('employee_loans_retry_button'),
          onPressed: viewModel.loadLoans,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryButton),
        ),
      ),
      emptyBuilder: (context) => PointyEmptyState(
        icon: Icons.account_balance_wallet_outlined,
        title: l10n.emptyEmployeeLoans,
        message: l10n.emptyEmployeeLoansHint,
      ),
      padding: EdgeInsets.zero,
      framed: false,
      itemBuilder: (context, loan) {
        return EmployeeLoanRow(
          loan: loan,
          actions: [
            if (capabilities.canManageEmployeeLoans && loan.status.canReview)
              EmployeeLoanReviewActions(
                loan: loan,
                isSaving: viewModel.isSaving,
                onApprove: (disbursement) =>
                    viewModel.approveLoan(loan, disbursement: disbursement),
                onReject: () => viewModel.rejectLoan(loan),
              ),
          ],
        );
      },
    );
    if (!capabilities.canCreateEmployeeLoans) {
      return list;
    }

    // The same place the employees tab keeps its "add": above the list.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: spacing.xs),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            key: const ValueKey('new_employee_loan_button'),
            onPressed: viewModel.isSaving
                ? null
                : () => showEmployeeLoanSheet(
                    context,
                    viewModel: viewModel,
                    capabilities: capabilities,
                  ),
            icon: const Icon(Icons.add),
            label: Text(l10n.newEmployeeLoanTitle),
          ),
        ),
        SizedBox(height: spacing.sm),
        Expanded(child: list),
      ],
    );
  }
}
