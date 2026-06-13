import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/employee.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../attendance/view_models/attendance_view_model.dart';
import '../view_models/employee_payroll_view_model.dart';
import 'payroll_adjustment_sheets.dart';
import 'payroll_labels.dart';

/// Full-screen payroll run review: totals up top, one employee per row, and a
/// single next-step action (approve, then record payment) pinned at the
/// bottom.
class PayrollRunDetailsScreen extends StatefulWidget {
  const PayrollRunDetailsScreen({
    super.key,
    required this.viewModel,
    required this.attendanceViewModel,
    required this.capabilities,
    required this.initialRun,
  });

  final EmployeePayrollViewModel viewModel;
  final AttendanceViewModel attendanceViewModel;
  final AuthorizationCapabilities capabilities;
  final PayrollRun initialRun;

  @override
  State<PayrollRunDetailsScreen> createState() =>
      _PayrollRunDetailsScreenState();
}

class _PayrollRunDetailsScreenState extends State<PayrollRunDetailsScreen> {
  PayrollRun? _run;
  bool _isLoading = true;
  bool _loadFailed = false;
  bool _isApplyingAttendance = false;

  PayrollRun get _activeRun => _run ?? widget.initialRun;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _loadFailed = false;
    });
    final run = await widget.viewModel.loadPayrollRunDetail(widget.initialRun);
    if (!mounted) {
      return;
    }
    setState(() {
      if (run != null) {
        _run = run;
      }
      _loadFailed = run == null;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final run = _activeRun;
    final canManage = widget.capabilities.canManagePayroll;

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.payrollRunDetailsTitle(run.runNumber)),
            actions: [
              IconButton(
                tooltip: l10n.refreshEmployeePayrollTooltip,
                onPressed: _isLoading ? null : _load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          backgroundColor: colors.page,
          body: _isLoading && _run == null
              ? const PointyLoadingArea(minHeight: 320)
              : _loadFailed && _run == null
              ? Center(
                  child: PointyErrorState(
                    title: l10n.payrollRunDetailsLoadError,
                    icon: Icons.warning_amber_outlined,
                  ),
                )
              : _PayrollRunDetailsBody(
                  run: run,
                  viewModel: widget.viewModel,
                  canManage: canManage,
                  showAttendanceAction: widget.capabilities.canViewAttendance,
                  isApplyingAttendance: _isApplyingAttendance,
                  onApplyAttendance: _applyAttendance,
                  onRunChanged: (updated) => setState(() => _run = updated),
                ),
          bottomNavigationBar: _buildActionFooter(context, l10n, run, canManage),
        );
      },
    );
  }

  Widget? _buildActionFooter(
    BuildContext context,
    AppLocalizations l10n,
    PayrollRun run,
    bool canManage,
  ) {
    if (!canManage || (_isLoading && _run == null)) {
      return null;
    }
    final isSaving = widget.viewModel.isSaving;

    if (run.status.canApprove) {
      return PointyStickyActionFooter(
        secondaryActions: [
          OutlinedButton.icon(
            key: const ValueKey('payroll_details_bulk_adjust_button'),
            onPressed: isSaving || run.lines.isEmpty
                ? null
                : () => _openBulkAdjustment(context),
            icon: const Icon(Icons.playlist_add_check_outlined),
            label: Text(l10n.payrollBulkAdjustmentButton),
          ),
        ],
        primaryAction: FilledButton.icon(
          key: const ValueKey('payroll_details_approve_button'),
          onPressed: isSaving || run.lines.isEmpty ? null : _confirmApprove,
          icon: const Icon(Icons.verified_outlined),
          label: Text(l10n.approvePayrollConfirmButton),
        ),
      );
    }

    if (run.status.canPay) {
      return PointyStickyActionFooter(
        primaryAction: FilledButton.icon(
          key: const ValueKey('payroll_details_mark_paid_button'),
          onPressed: isSaving ? null : _confirmMarkPaid,
          icon: const Icon(Icons.price_check_outlined),
          label: Text(l10n.recordPayrollPaymentButton),
        ),
      );
    }

    return null;
  }

  Future<void> _openBulkAdjustment(BuildContext context) async {
    final updated = await showPayrollBulkAdjustmentSheet(
      context,
      run: _activeRun,
      viewModel: widget.viewModel,
    );
    if (updated != null && mounted) {
      setState(() => _run = updated);
    }
  }

  Future<void> _applyAttendance() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isApplyingAttendance = true);
    final updated = await widget.attendanceViewModel.applyToPayrollRun(
      _activeRun.id,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _isApplyingAttendance = false;
      if (updated != null) {
        _run = updated;
      }
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          updated != null
              ? l10n.attendanceApplySuccess
              : l10n.attendanceApplyFailed,
        ),
      ),
    );
  }

  Future<void> _confirmApprove() async {
    final l10n = AppLocalizations.of(context)!;
    final run = _activeRun;
    final confirmed = await _showConfirmation(
      title: l10n.approvePayrollConfirmTitle,
      message: l10n.approvePayrollConfirmMessage(
        l10n.payrollLineCount(run.lines.length),
        formatMoney(run.netTotal),
      ),
      confirmLabel: l10n.approvePayrollConfirmButton,
      icon: Icons.verified_outlined,
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final saved = await widget.viewModel.approvePayrollRun(run);
    if (saved && mounted) {
      await _load();
    }
  }

  Future<void> _confirmMarkPaid() async {
    final l10n = AppLocalizations.of(context)!;
    final run = _activeRun;
    final confirmed = await _showConfirmation(
      title: l10n.markPayrollPaidConfirmTitle,
      message: l10n.markPayrollPaidConfirmMessage(formatMoney(run.netTotal)),
      confirmLabel: l10n.markPayrollPaidConfirmButton,
      icon: Icons.price_check_outlined,
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final saved = await widget.viewModel.markPayrollRunPaid(run);
    if (saved && mounted) {
      await _load();
    }
  }

  Future<bool?> _showConfirmation({
    required String title,
    required String message,
    required String confirmLabel,
    required IconData icon,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          icon: Icon(icon),
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancelButton),
            ),
            FilledButton(
              key: const ValueKey('payroll_confirm_dialog_button'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
  }
}

class _PayrollRunDetailsBody extends StatelessWidget {
  const _PayrollRunDetailsBody({
    required this.run,
    required this.viewModel,
    required this.canManage,
    required this.showAttendanceAction,
    required this.isApplyingAttendance,
    required this.onApplyAttendance,
    required this.onRunChanged,
  });

  final PayrollRun run;
  final EmployeePayrollViewModel viewModel;
  final bool canManage;
  final bool showAttendanceAction;
  final bool isApplyingAttendance;
  final Future<void> Function() onApplyAttendance;
  final ValueChanged<PayrollRun> onRunChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final canEditLines = canManage && run.status == PayrollStatus.draft;

    return SingleChildScrollView(
      padding: spacing.pagePadding,
      child: AdaptiveMaxWidth(
        width: AppContentWidth.workspace,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _RunHeaderCard(run: run),
            SizedBox(height: spacing.md),
            if (canEditLines && showAttendanceAction) ...[
              _AttendanceApplyCard(
                isApplying: isApplyingAttendance,
                onApply: onApplyAttendance,
              ),
              SizedBox(height: spacing.md),
            ],
            PointyMetricGrid(
              maxColumns: 4,
              minTileWidth: 160,
              metrics: [
                PointyMetricGridItem(
                  label: l10n.payrollRunGrossTotalLabel,
                  value: formatMoney(run.grossTotal),
                  icon: Icons.account_balance_wallet_outlined,
                ),
                PointyMetricGridItem(
                  label: l10n.payrollRunAdditionsTotalLabel,
                  value: formatMoney(run.additionsTotal),
                  icon: Icons.add_circle_outline,
                  accentColor: colors.success,
                ),
                PointyMetricGridItem(
                  label: l10n.payrollRunDeductionsTotalLabel,
                  value: formatMoney(run.deductionsTotal),
                  icon: Icons.remove_circle_outline,
                  accentColor: colors.danger,
                ),
                PointyMetricGridItem(
                  label: l10n.payrollRunNetTotalLabel,
                  value: formatMoney(run.netTotal),
                  icon: Icons.payments_outlined,
                  accentColor: colors.primaryStrong,
                ),
              ],
            ),
            SizedBox(height: spacing.md),
            PointyDetailSection(
              title: l10n.payrollRunEmployeesSection,
              icon: Icons.groups_outlined,
              trailing: Text(
                l10n.payrollLineCount(run.lines.length),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colors.mutedInk,
                ),
              ),
              child: run.lines.isEmpty
                  ? PointyEmptyState(
                      icon: Icons.groups_outlined,
                      title: l10n.payrollRunNoEmployees,
                    )
                  : Column(
                      children: [
                        if (canEditLines)
                          Padding(
                            padding: EdgeInsetsDirectional.only(
                              bottom: spacing.sm,
                            ),
                            child: PointyInlineMessage(
                              message: l10n.payrollLineTapToAdjustHint,
                              icon: Icons.touch_app_outlined,
                              compact: true,
                            ),
                          ),
                        for (final line in run.lines) ...[
                          _PayrollLineTile(
                            run: run,
                            line: line,
                            viewModel: viewModel,
                            canEdit: canEditLines,
                            onRunChanged: onRunChanged,
                          ),
                          SizedBox(height: spacing.sm),
                        ],
                      ],
                    ),
            ),
            if (run.notes.trim().isNotEmpty) ...[
              SizedBox(height: spacing.md),
              PointyDetailSection(
                title: l10n.payrollRunNotesLabel,
                icon: Icons.notes_outlined,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(run.notes.trim()),
                ),
              ),
            ],
            // Leave room so the last row is reachable above the sticky footer.
            SizedBox(height: spacing.lg),
          ],
        ),
      ),
    );
  }
}

class _AttendanceApplyCard extends StatelessWidget {
  const _AttendanceApplyCard({
    required this.isApplying,
    required this.onApply,
  });

  final bool isApplying;
  final Future<void> Function() onApply;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.fingerprint),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: Text(
                    l10n.attendanceApplyCardTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            SizedBox(height: spacing.xs),
            Text(
              l10n.attendanceApplyCardSubtitle,
              style: theme.textTheme.bodySmall,
            ),
            SizedBox(height: spacing.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonalIcon(
                key: const ValueKey('payroll_details_apply_attendance_button'),
                onPressed: isApplying ? null : () => onApply(),
                icon: isApplying
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(
                  isApplying
                      ? l10n.attendanceApplyInProgressButton
                      : l10n.attendanceApplyToPayrollButton,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RunHeaderCard extends StatelessWidget {
  const _RunHeaderCard({required this.run});

  final PayrollRun run;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final statusColor = payrollStatusColor(context, run.status);

    final timeline = <(String, String)>[
      if (run.createdAt != null)
        (l10n.payrollRunCreatedAtLabel, formatDateTime(run.createdAt!)),
      if (run.approvedAt != null)
        (
          l10n.payrollRunApprovedByLabel,
          _actorWithDate(l10n, run.approvedByUsername, run.approvedAt!),
        ),
      if (run.paidAt != null)
        (
          l10n.payrollRunPaidByLabel,
          _actorWithDate(l10n, run.paidByUsername, run.paidAt!),
        ),
      if (run.paymentDate != null)
        (l10n.payrollRunPaymentDateLabel, formatDate(run.paymentDate!)),
    ];

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: spacing.compactPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        run.periodStart != null
                            ? payrollMonthLabel(context, run.periodStart!)
                            : run.runNumber,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: spacing.xs),
                      Text(
                        payrollPeriodLabel(l10n, run),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
                PointyStatusPill(
                  label: payrollStatusLabel(l10n, run.status),
                  icon: payrollStatusIcon(run.status),
                  color: statusColor,
                  compact: false,
                ),
              ],
            ),
            if (timeline.isNotEmpty) ...[
              Divider(height: spacing.lg, color: colors.line),
              for (final (label, value) in timeline)
                PointyDetailRow(label: label, value: value),
            ],
          ],
        ),
      ),
    );
  }

  String _actorWithDate(AppLocalizations l10n, String actor, DateTime date) {
    final formattedDate = formatDateTime(date);
    if (actor.trim().isEmpty) {
      return formattedDate;
    }
    return l10n.payrollRunActorWithDate(actor.trim(), formattedDate);
  }
}

class _PayrollLineTile extends StatelessWidget {
  const _PayrollLineTile({
    required this.run,
    required this.line,
    required this.viewModel,
    required this.canEdit,
    required this.onRunChanged,
  });

  final PayrollRun run;
  final PayrollLine line;
  final EmployeePayrollViewModel viewModel;
  final bool canEdit;
  final ValueChanged<PayrollRun> onRunChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final title = payrollEmployeeLineTitle(l10n, line);
    final hasModifiers =
        line.additionsAmount > 0 ||
        line.deductionsAmount > 0 ||
        line.absenceDays > 0;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('payroll_line_tile_${line.id}'),
        onTap: canEdit && !viewModel.isSaving
            ? () => _openAdjustmentSheet(context)
            : null,
        child: Padding(
          padding: spacing.compactPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    child: Text(title.isEmpty ? '#' : title.characters.first),
                  ),
                  SizedBox(width: spacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: spacing.xs),
                        Text(
                          payrollLinePayLabel(l10n, line),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: spacing.sm),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        formatMoney(line.netAmount),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (line.grossAmount != line.netAmount) ...[
                        SizedBox(height: spacing.xs),
                        Text(
                          formatMoney(line.grossAmount),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                            decoration: TextDecoration.lineThrough,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (canEdit) ...[
                    SizedBox(width: spacing.xs),
                    Icon(Icons.chevron_left, color: colors.mutedInk),
                  ],
                ],
              ),
              if (hasModifiers || line.adjustments.isNotEmpty) ...[
                SizedBox(height: spacing.sm),
                Wrap(
                  spacing: spacing.xs,
                  runSpacing: spacing.xs,
                  children: [
                    if (line.additionsAmount > 0)
                      PointyStatusPill(
                        label: l10n.payrollAdditionsChipLabel(
                          formatMoney(line.additionsAmount),
                        ),
                        icon: Icons.add_circle_outline,
                        color: colors.success,
                      ),
                    if (line.deductionsAmount > 0)
                      PointyStatusPill(
                        label: l10n.payrollDeductionsChipLabel(
                          formatMoney(line.deductionsAmount),
                        ),
                        icon: Icons.remove_circle_outline,
                        color: colors.danger,
                      ),
                    if (line.absenceDays > 0)
                      PointyStatusPill(
                        label: l10n.payrollAbsenceChipLabel(
                          line.absenceDays.toStringAsFixed(
                            line.absenceDays.truncateToDouble() ==
                                    line.absenceDays
                                ? 0
                                : 1,
                          ),
                        ),
                        icon: Icons.event_busy_outlined,
                        color: colors.warning,
                      ),
                  ],
                ),
              ],
              if (line.adjustments.isNotEmpty) ...[
                Divider(height: spacing.lg, color: colors.line),
                for (final adjustment in line.adjustments)
                  PointyDetailRow(
                    label: l10n.payrollAdjustmentDetailLabel(
                      payrollAdjustmentDirectionLabel(
                        l10n,
                        adjustment.direction,
                      ),
                      payrollAdjustmentTypeLabel(
                        l10n,
                        adjustment.adjustmentType,
                      ),
                    ),
                    value: adjustment.notes.trim().isEmpty
                        ? formatMoney(adjustment.amount)
                        : l10n.payrollAdjustmentAmountWithNotes(
                            formatMoney(adjustment.amount),
                            adjustment.notes.trim(),
                          ),
                  ),
              ],
              if (line.notes.trim().isNotEmpty) ...[
                SizedBox(height: spacing.xs),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    line.notes.trim(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openAdjustmentSheet(BuildContext context) async {
    final updated = await showPayrollLineAdjustmentSheet(
      context,
      run: run,
      line: line,
      viewModel: viewModel,
    );
    if (updated != null) {
      onRunChanged(updated);
    }
  }
}
