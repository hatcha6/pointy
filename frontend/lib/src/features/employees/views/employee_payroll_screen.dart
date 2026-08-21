import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/employee.dart';
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
import 'employee_loan_review_actions.dart';
import 'payroll_forms.dart';
import 'payroll_labels.dart';
import 'payroll_run_details_screen.dart';

/// Employees & payroll workspace. The payroll tab is task-first: a single
/// "this month" card walks the owner through prepare → approve → pay, with
/// pending loan requests surfaced underneath and history below.
class EmployeePayrollScreen extends StatelessWidget {
  const EmployeePayrollScreen({
    super.key,
    required this.viewModel,
    required this.attendanceViewModel,
    required this.userRepository,
    required this.capabilities,
    required this.navigation,
  });

  final EmployeePayrollViewModel viewModel;
  final AttendanceViewModel attendanceViewModel;
  final UserRepository userRepository;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;

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
  });

  final EmployeePayrollViewModel viewModel;
  final AttendanceViewModel attendanceViewModel;
  final UserRepository userRepository;
  final AuthorizationCapabilities capabilities;

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
                      capabilities: capabilities,
                    ),
                    _EmployeesTab(
                      viewModel: viewModel,
                      userRepository: userRepository,
                      capabilities: capabilities,
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
    required this.capabilities,
  });

  final EmployeePayrollViewModel viewModel;
  final AttendanceViewModel attendanceViewModel;
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
        _MonthWorkflowCard(
          viewModel: viewModel,
          attendanceViewModel: attendanceViewModel,
          capabilities: capabilities,
        ),
        if (pendingLoans.isNotEmpty &&
            capabilities.canManageEmployeeLoans) ...[
          SizedBox(height: spacing.md),
          _PendingLoansCard(viewModel: viewModel, loans: pendingLoans),
        ],
        SizedBox(height: spacing.md),
        PointySectionHeader(
          title: l10n.payrollHistoryTitle,
          leading: const Icon(Icons.history_outlined),
          actions: [
            if (capabilities.canManagePayroll)
              OutlinedButton.icon(
                key: const ValueKey('payroll_custom_run_button'),
                onPressed: viewModel.isSaving
                    ? null
                    : () => _showCreatePayrollSheet(context),
                icon: const Icon(Icons.add_outlined),
                label: Text(l10n.customPayrollRunButton),
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

  Future<void> _showCreatePayrollSheet(BuildContext context) {
    return showAdaptiveFormSurface<void>(
      context: context,
      size: AdaptiveModalSize.standard,
      builder: (sheetContext) => CreatePayrollRunForm(
        viewModel: viewModel,
        onCreated: () => Navigator.of(sheetContext).pop(),
      ),
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

class _MonthWorkflowCard extends StatelessWidget {
  const _MonthWorkflowCard({
    required this.viewModel,
    required this.attendanceViewModel,
    required this.capabilities,
  });

  final EmployeePayrollViewModel viewModel;
  final AttendanceViewModel attendanceViewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final run = viewModel.currentMonthRun;
    final needsOnboarding =
        run == null &&
        viewModel.employees.isEmpty &&
        !viewModel.isLoadingEmployees &&
        !viewModel.hasEmployeeError;

    return Card(
      key: const ValueKey('payroll_month_workflow_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: spacing.compactPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.calendar_month_outlined,
                  color: colors.primaryStrong,
                ),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: Text(
                    l10n.payrollMonthCardTitle(
                      payrollMonthLabel(context, DateTime.now()),
                    ),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (run != null)
                  PointyStatusPill(
                    label: payrollStatusLabel(l10n, run.status),
                    icon: payrollStatusIcon(run.status),
                    color: payrollStatusColor(context, run.status),
                  ),
              ],
            ),
            SizedBox(height: spacing.md),
            _WorkflowStepper(status: run?.status),
            SizedBox(height: spacing.md),
            if (run != null) ...[
              Row(
                children: [
                  Expanded(
                    child: _WorkflowMetric(
                      label: l10n.payrollRunNetTotalLabel,
                      value: formatMoney(run.netTotal),
                    ),
                  ),
                  SizedBox(width: spacing.sm),
                  Expanded(
                    child: _WorkflowMetric(
                      label: l10n.payrollRunEmployeesSection,
                      value: l10n.payrollLineCount(run.lineCount),
                    ),
                  ),
                ],
              ),
              SizedBox(height: spacing.md),
            ],
            Text(
              _statusMessage(l10n, run, needsOnboarding),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: run?.status == PayrollStatus.paid
                    ? colors.success
                    : colors.mutedInk,
                fontWeight: run?.status == PayrollStatus.paid
                    ? FontWeight.w700
                    : null,
              ),
            ),
            SizedBox(height: spacing.sm),
            _buildAction(context, l10n, run, needsOnboarding),
          ],
        ),
      ),
    );
  }

  String _statusMessage(
    AppLocalizations l10n,
    PayrollRun? run,
    bool needsOnboarding,
  ) {
    if (needsOnboarding) {
      return l10n.payrollMonthOnboardingMessage;
    }
    return switch (run?.status) {
      null => l10n.payrollMonthNoRunMessage,
      PayrollStatus.draft => l10n.payrollMonthDraftMessage,
      PayrollStatus.approved => l10n.payrollMonthApprovedMessage,
      PayrollStatus.paid => l10n.payrollMonthPaidMessage,
      PayrollStatus.voided => l10n.payrollMonthNoRunMessage,
    };
  }

  Widget _buildAction(
    BuildContext context,
    AppLocalizations l10n,
    PayrollRun? run,
    bool needsOnboarding,
  ) {
    if (needsOnboarding) {
      return FilledButton.tonalIcon(
        onPressed: capabilities.canManageEmployees
            ? () => DefaultTabController.of(context).animateTo(1)
            : null,
        icon: const Icon(Icons.person_add_alt_1),
        label: Text(l10n.addEmployeeButton),
      );
    }

    if (run == null) {
      return FilledButton.icon(
        key: const ValueKey('payroll_prepare_month_button'),
        onPressed: capabilities.canManagePayroll && !viewModel.isSaving
            ? () => _prepareMonth(context)
            : null,
        icon: const Icon(Icons.play_circle_outline),
        label: Text(l10n.preparePayrollMonthButton),
      );
    }

    return switch (run.status) {
      PayrollStatus.draft => FilledButton.icon(
        key: const ValueKey('payroll_review_approve_button'),
        onPressed: () => _openRunDetails(context, run),
        icon: const Icon(Icons.fact_check_outlined),
        label: Text(l10n.reviewAndApprovePayrollButton),
      ),
      PayrollStatus.approved => FilledButton.icon(
        key: const ValueKey('payroll_record_payment_button'),
        onPressed: () => _openRunDetails(context, run),
        icon: const Icon(Icons.price_check_outlined),
        label: Text(l10n.recordPayrollPaymentButton),
      ),
      _ => FilledButton.tonalIcon(
        key: const ValueKey('payroll_view_run_button'),
        onPressed: () => _openRunDetails(context, run),
        icon: const Icon(Icons.visibility_outlined),
        label: Text(l10n.viewPayrollRunButton),
      ),
    };
  }

  Future<void> _prepareMonth(BuildContext context) async {
    final run = await viewModel.draftMonthlyPayrollRun();
    if (run != null && context.mounted) {
      _openRunDetails(context, run);
    }
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

class _WorkflowMetric extends StatelessWidget {
  const _WorkflowMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.subtleFill,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.mutedInk,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkflowStepper extends StatelessWidget {
  const _WorkflowStepper({required this.status});

  /// Null when this month has no run yet (nothing done, first step active).
  final PayrollStatus? status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final completedSteps = switch (status) {
      null || PayrollStatus.voided => 0,
      PayrollStatus.draft => 1,
      PayrollStatus.approved => 2,
      PayrollStatus.paid => 3,
    };
    final labels = [
      l10n.payrollMonthStepPrepare,
      l10n.payrollMonthStepApprove,
      l10n.payrollMonthStepPay,
    ];

    return Row(
      children: [
        for (var index = 0; index < labels.length; index++) ...[
          if (index > 0)
            Expanded(
              child: Divider(
                thickness: 2,
                color: index < completedSteps + 1
                    ? context.pointyColors.success
                    : context.pointyColors.line,
              ),
            ),
          _WorkflowStep(
            label: labels[index],
            isDone: index < completedSteps,
            isActive: index == completedSteps,
          ),
        ],
      ],
    );
  }
}

class _WorkflowStep extends StatelessWidget {
  const _WorkflowStep({
    required this.label,
    required this.isDone,
    required this.isActive,
  });

  final String label;
  final bool isDone;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final color = isDone
        ? colors.success
        : isActive
        ? colors.primaryStrong
        : colors.mutedInk;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDone ? colors.success : Colors.transparent,
              border: Border.all(color: color, width: 2),
            ),
            child: SizedBox.square(
              dimension: 26,
              child: Icon(
                isDone ? Icons.check : Icons.circle,
                size: isDone ? 16 : 8,
                color: isDone ? colors.surface : color,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: isActive || isDone ? FontWeight.w800 : null,
            ),
          ),
        ],
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
                Icon(Icons.notifications_active_outlined, color: colors.warning),
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
          onApprove: () => viewModel.approveLoan(loan),
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
  });

  final EmployeePayrollViewModel viewModel;
  final UserRepository userRepository;
  final AuthorizationCapabilities capabilities;

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
                  : () => _showCreateEmployeeSheet(context),
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
              return PointyDataRow(
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
                ],
                actions: [
                  if (capabilities.canManageEmployees)
                    TextButton.icon(
                      key: ValueKey('employee_plan_button_${employee.id}'),
                      onPressed: viewModel.isSaving
                          ? null
                          : () => _showCompensationSheet(context, employee),
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

  Future<void> _showCreateEmployeeSheet(BuildContext context) {
    return showAdaptiveFormSurface<void>(
      context: context,
      size: AdaptiveModalSize.standard,
      builder: (sheetContext) => CreateEmployeeForm(
        viewModel: viewModel,
        userRepository: userRepository,
        onCreated: () => Navigator.of(sheetContext).pop(),
      ),
    );
  }

  Future<void> _showCompensationSheet(BuildContext context, Employee employee) {
    return showAdaptiveFormSurface<void>(
      context: context,
      size: AdaptiveModalSize.standard,
      builder: (sheetContext) => CompensationPlanForm(
        viewModel: viewModel,
        employee: employee,
        onCreated: () => Navigator.of(sheetContext).pop(),
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
    return PointyDataList<EmployeeLoan>(
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
      ),
      padding: EdgeInsets.zero,
      framed: false,
      itemBuilder: (context, loan) {
        final canReview =
            capabilities.canManageEmployeeLoans && loan.status.canReview;
        return PointyDataRow(
          leading: const CircleAvatar(
            child: Icon(Icons.account_balance_wallet_outlined),
          ),
          title: loan.employeeName,
          subtitle: _loanSubtitle(l10n, loan),
          trailing: Text(
            formatMoney(loan.outstandingBalance),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          badges: [
            PointyStatusPill(
              label: loanStatusLabel(l10n, loan.status),
              icon: loanStatusIcon(loan.status),
              color: loanStatusColor(context, loan.status),
            ),
            PointyStatusPill(
              label: l10n.employeeLoanMonthlyDeductionDetail(
                formatMoney(loan.monthlyDeduction),
              ),
              icon: Icons.event_repeat_outlined,
            ),
          ],
          actions: [
            if (canReview)
              EmployeeLoanReviewActions(
                loan: loan,
                isSaving: viewModel.isSaving,
                onApprove: () => viewModel.approveLoan(loan),
                onReject: () => viewModel.rejectLoan(loan),
              ),
          ],
        );
      },
    );
  }

  String _loanSubtitle(AppLocalizations l10n, EmployeeLoan loan) {
    final parts = [
      if (loan.employeeNumber.isNotEmpty) loan.employeeNumber,
      l10n.employeeLoanAmountDetail(formatMoney(loan.amount)),
      if (loan.purpose.trim().isNotEmpty) loan.purpose.trim(),
    ];
    return parts.join(' - ');
  }
}
