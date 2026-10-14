import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/employee.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/employee_payroll_view_model.dart';
import 'payroll_labels.dart';

/// The payroll tab's one task card: a month walked through prepare → approve
/// → pay. Before the month has a run it is a checklist of what preparing
/// needs — employees, then a salary plan for each — so a manager is never
/// handed a button that can only fail.
class PayrollMonthCard extends StatelessWidget {
  const PayrollMonthCard({
    super.key,
    required this.viewModel,
    required this.capabilities,
    required this.onOpenRun,
    required this.onAddEmployee,
    required this.onSetSalary,
    required this.onShowEmployees,
  });

  /// How many employees without a plan the card names; the rest are a link
  /// to the employees tab.
  static const int maxMissingShown = 3;

  final EmployeePayrollViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final ValueChanged<PayrollRun> onOpenRun;
  final VoidCallback onAddEmployee;
  final ValueChanged<Employee> onSetSalary;
  final VoidCallback onShowEmployees;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final run = viewModel.payrollMonthRun;
    final monthLabel = payrollMonthLabel(
      context,
      viewModel.payrollMonthPeriod.start,
    );

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
                // The stepper below says the status; the row keeps to the
                // month and its arrows, so a phone fits it on one line.
                Expanded(
                  child: Text(
                    l10n.payrollMonthCardTitle(monthLabel),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('payroll_month_previous_button'),
                  tooltip: l10n.payrollMonthPreviousTooltip,
                  onPressed: viewModel.isSaving
                      ? null
                      : viewModel.showPreviousPayrollMonth,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  key: const ValueKey('payroll_month_next_button'),
                  tooltip: l10n.payrollMonthNextTooltip,
                  onPressed:
                      viewModel.canShowNextPayrollMonth && !viewModel.isSaving
                      ? viewModel.showNextPayrollMonth
                      : null,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            SizedBox(height: spacing.md),
            _WorkflowStepper(status: run?.status),
            SizedBox(height: spacing.md),
            if (run == null)
              ..._buildReadiness(context, l10n, monthLabel)
            else
              ..._buildRunState(context, l10n, run),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildRunState(
    BuildContext context,
    AppLocalizations l10n,
    PayrollRun run,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final paid = run.status == PayrollStatus.paid;
    final hint = switch (run.status) {
      PayrollStatus.draft => l10n.payrollMonthDraftHint,
      PayrollStatus.approved => l10n.payrollMonthApprovedHint,
      _ => null,
    };

    return [
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
      Text(
        switch (run.status) {
          PayrollStatus.draft => l10n.payrollMonthDraftMessage,
          PayrollStatus.approved => l10n.payrollMonthApprovedMessage,
          PayrollStatus.paid => l10n.payrollMonthPaidMessage,
          PayrollStatus.voided => l10n.payrollMonthNoRunMessage,
        },
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: paid ? colors.success : null,
          fontWeight: FontWeight.w700,
        ),
      ),
      if (hint != null) ...[
        const SizedBox(height: 2),
        Text(
          hint,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
      ],
      SizedBox(height: spacing.sm),
      switch (run.status) {
        PayrollStatus.draft => FilledButton.icon(
          key: const ValueKey('payroll_review_approve_button'),
          onPressed: () => onOpenRun(run),
          icon: const Icon(Icons.fact_check_outlined),
          label: Text(l10n.reviewAndApprovePayrollButton),
        ),
        PayrollStatus.approved => FilledButton.icon(
          key: const ValueKey('payroll_record_payment_button'),
          onPressed: () => onOpenRun(run),
          icon: const Icon(Icons.price_check_outlined),
          label: Text(l10n.recordPayrollPaymentButton),
        ),
        _ => FilledButton.tonalIcon(
          key: const ValueKey('payroll_view_run_button'),
          onPressed: () => onOpenRun(run),
          icon: const Icon(Icons.visibility_outlined),
          label: Text(l10n.viewPayrollRunButton),
        ),
      },
    ];
  }

  List<Widget> _buildReadiness(
    BuildContext context,
    AppLocalizations l10n,
    String monthLabel,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final employees = viewModel.payrollEmployees;
    final ready = viewModel.employeesReadyForPayroll;
    final missing = viewModel.employeesMissingPayrollPlan;
    // Paid from the day they started, not the whole month: said before the
    // run is made, so a hire date left at its default is caught here.
    final newHires = viewModel.employeesHiredDuringPayrollMonth;
    final stillLoading = viewModel.isLoadingEmployees && employees.isEmpty;
    final canManageEmployees = capabilities.canManageEmployees;
    // Only a whole roster can prove nobody has a plan; a first page cannot.
    final blocked =
        employees.isEmpty || (viewModel.hasWholeRoster && ready.isEmpty);

    return [
      Text(
        l10n.payrollMonthNoRunMessage,
        style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
      ),
      SizedBox(height: spacing.sm),
      // Once every employee is ready the checklist has nothing to ask for;
      // the hint under the button says who the run will cover.
      if (!stillLoading && (employees.isEmpty || missing.isNotEmpty)) ...[
        _ReadinessStep(
          key: const ValueKey('payroll_readiness_employees'),
          index: 1,
          done: employees.isNotEmpty,
          title: l10n.payrollReadinessEmployeesStep,
          detail: employees.isEmpty
              ? null
              : l10n.payrollReadinessEmployeesDone(employees.length),
          action: employees.isEmpty
              ? FilledButton.tonalIcon(
                  key: const ValueKey('payroll_readiness_add_employee_button'),
                  onPressed: canManageEmployees && !viewModel.isSaving
                      ? onAddEmployee
                      : null,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: Text(l10n.addEmployeeButton),
                )
              : null,
        ),
        _ReadinessStep(
          key: const ValueKey('payroll_readiness_plans'),
          index: 2,
          done: employees.isNotEmpty && missing.isEmpty,
          title: l10n.payrollReadinessPlansStep,
          detail: employees.isEmpty
              ? null
              : l10n.payrollReadinessPlansProgress(
                  ready.length,
                  employees.length,
                ),
          children: [
            for (final employee in missing.take(maxMissingShown))
              _MissingPlanRow(
                employee: employee,
                reason: _missingReason(l10n, employee),
                onSetSalary: canManageEmployees && !viewModel.isSaving
                    ? () => onSetSalary(employee)
                    : null,
              ),
            if (missing.length > maxMissingShown)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  key: const ValueKey('payroll_readiness_more_missing'),
                  onPressed: onShowEmployees,
                  child: Text(
                    l10n.payrollReadinessMoreMissing(
                      missing.length - maxMissingShown,
                    ),
                  ),
                ),
              ),
          ],
        ),
        SizedBox(height: spacing.sm),
      ],
      if (viewModel.monthDraftFoundNoPlans) ...[
        PointyInlineMessage.warning(
          key: const ValueKey('payroll_month_no_plans_message'),
          message: l10n.payrollMonthNoPlansMessage(monthLabel),
        ),
        SizedBox(height: spacing.sm),
      ],
      FilledButton.icon(
        key: const ValueKey('payroll_prepare_month_button'),
        onPressed:
            capabilities.canManagePayroll && !viewModel.isSaving && !blocked
            ? () => _prepareMonth()
            : null,
        icon: const Icon(Icons.play_circle_outline),
        label: Text(l10n.preparePayrollMonthButton),
      ),
      if (!stillLoading) ...[
        SizedBox(height: spacing.xs),
        Text(
          key: const ValueKey('payroll_prepare_hint'),
          blocked ? l10n.payrollPrepareBlockedHint : l10n.payrollPrepareHint,
          style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
        if (!blocked && missing.isNotEmpty)
          Text(
            key: const ValueKey('payroll_prepare_skips_hint'),
            l10n.payrollPrepareSkipsHint(missing.length),
            style: textTheme.bodySmall?.copyWith(
              color: colors.warning,
              fontWeight: FontWeight.w700,
            ),
          ),
        if (!blocked && newHires.isNotEmpty)
          Text(
            key: const ValueKey('payroll_prepare_prorated_hint'),
            l10n.payrollPrepareProratedHint(
              newHires.map((employee) => employee.fullName).join('، '),
            ),
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
      ],
    ];
  }

  String _missingReason(AppLocalizations l10n, Employee employee) {
    final plan = employee.activeCompensationPlan;
    final from = plan?.effectiveFrom;
    if (plan == null ||
        !plan.isActive ||
        from == null ||
        !from.isAfter(viewModel.payrollMonthPeriod.end)) {
      return l10n.payrollReadinessNoPlan;
    }
    // Fixed by a plan dated from the hire date, which the salary sheet
    // offers for exactly this case.
    return l10n.payrollReadinessPlanStartsLater(formatDate(from));
  }

  Future<void> _prepareMonth() async {
    final run = await viewModel.draftMonthlyPayrollRun();
    if (run != null) {
      onOpenRun(run);
    }
  }
}

class _ReadinessStep extends StatelessWidget {
  const _ReadinessStep({
    super.key,
    required this.index,
    required this.done,
    required this.title,
    this.detail,
    this.action,
    this.children = const [],
  });

  final int index;
  final bool done;
  final String title;
  final String? detail;
  final Widget? action;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final color = done ? colors.success : colors.primaryStrong;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? colors.success : Colors.transparent,
              border: Border.all(color: color, width: 2),
            ),
            child: SizedBox.square(
              dimension: 24,
              child: Center(
                child: done
                    ? Icon(Icons.check, size: 15, color: colors.surface)
                    : Text(
                        '$index',
                        style: textTheme.labelMedium?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (detail case final detail?)
                  Text(
                    detail,
                    style: textTheme.bodySmall?.copyWith(
                      color: done ? colors.success : colors.mutedInk,
                    ),
                  ),
                ...children,
                if (action case final action?) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: action,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MissingPlanRow extends StatelessWidget {
  const _MissingPlanRow({
    required this.employee,
    required this.reason,
    required this.onSetSalary,
  });

  final Employee employee;
  final String reason;
  final VoidCallback? onSetSalary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      key: ValueKey('payroll_missing_plan_${employee.id}'),
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(Icons.warning_amber_outlined, size: 18, color: colors.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: employee.fullName,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text: ' · $reason',
                    style: TextStyle(color: colors.mutedInk),
                  ),
                ],
              ),
              style: textTheme.bodyMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onSetSalary != null)
            TextButton(
              key: ValueKey('payroll_set_salary_${employee.id}'),
              onPressed: onSetSalary,
              child: Text(l10n.payrollSetSalaryButton),
            ),
        ],
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

  /// Null when the month has no run yet (nothing done, first step active).
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
