import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/employee.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/employee_payroll_view_model.dart';
import 'payroll_labels.dart';

/// Opens the single-line adjustment sheet and returns the updated run when
/// the change is saved.
Future<PayrollRun?> showPayrollLineAdjustmentSheet(
  BuildContext context, {
  required PayrollRun run,
  required PayrollLine line,
  required EmployeePayrollViewModel viewModel,
}) {
  return showAdaptiveModalBottomSheet<PayrollRun>(
    context: context,
    size: AdaptiveModalSize.standard,
    builder: (sheetContext) =>
        _PayrollLineAdjustmentSheet(run: run, line: line, viewModel: viewModel),
  );
}

/// Opens the bulk adjustment sheet and returns the updated run when applied.
Future<PayrollRun?> showPayrollBulkAdjustmentSheet(
  BuildContext context, {
  required PayrollRun run,
  required EmployeePayrollViewModel viewModel,
}) {
  return showAdaptiveModalBottomSheet<PayrollRun>(
    context: context,
    size: AdaptiveModalSize.standard,
    builder: (sheetContext) =>
        _PayrollBulkAdjustmentSheet(run: run, viewModel: viewModel),
  );
}

class _PayrollBulkAdjustmentSheet extends StatefulWidget {
  const _PayrollBulkAdjustmentSheet({
    required this.run,
    required this.viewModel,
  });

  final PayrollRun run;
  final EmployeePayrollViewModel viewModel;

  @override
  State<_PayrollBulkAdjustmentSheet> createState() =>
      _PayrollBulkAdjustmentSheetState();
}

class _PayrollBulkAdjustmentSheetState
    extends State<_PayrollBulkAdjustmentSheet> {
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  late Set<int> _selectedLineIds;
  PayrollBulkAdjustmentType _type = PayrollBulkAdjustmentType.addition;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _selectedLineIds = widget.run.lines.map((line) => line.id).toSet();
    _amountController.addListener(_refreshPreview);
  }

  @override
  void dispose() {
    _amountController
      ..removeListener(_refreshPreview)
      ..dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final amount = decimalValue(_amountController.text);
    final selectedCount = _selectedLineIds.length;
    final totalImpact = roundMoney(amount * selectedCount);
    final isDeduction = _type == PayrollBulkAdjustmentType.deduction;
    final showSelectionError = _submitted && selectedCount == 0;
    final showAmountError = _submitted && amount <= 0;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            PointySectionHeader(
              title: l10n.payrollBulkAdjustmentTitle,
              subtitle: l10n.payrollBulkAdjustmentSubtitle,
              leading: const Icon(Icons.playlist_add_check_outlined),
            ),
            SizedBox(height: spacing.md),
            SegmentedButton<PayrollBulkAdjustmentType>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: PayrollBulkAdjustmentType.addition,
                  icon: const Icon(Icons.add_circle_outline),
                  label: Text(l10n.payrollAdjustmentAddition),
                ),
                ButtonSegment(
                  value: PayrollBulkAdjustmentType.deduction,
                  icon: const Icon(Icons.remove_circle_outline),
                  label: Text(l10n.payrollAdjustmentDeduction),
                ),
                ButtonSegment(
                  value: PayrollBulkAdjustmentType.overtime,
                  icon: const Icon(Icons.more_time_outlined),
                  label: Text(l10n.payrollAdjustmentOvertime),
                ),
              ],
              selected: {_type},
              onSelectionChanged: widget.viewModel.isSaving
                  ? null
                  : (selection) {
                      setState(() {
                        _type = selection.single;
                      });
                    },
            ),
            SizedBox(height: spacing.sm),
            TextFormField(
              controller: _amountController,
              decoration: InputDecoration(
                labelText: l10n.payrollBulkAdjustmentAmountLabel,
                helperText: l10n.payrollBulkAdjustmentAmountHelper,
                errorText: showAmountError
                    ? l10n.payrollBulkPositiveAmountError
                    : null,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [DecimalTextInputFormatter()],
            ),
            SizedBox(height: spacing.sm),
            TextField(
              controller: _notesController,
              decoration: InputDecoration(
                labelText: l10n.payrollBulkAdjustmentNotesLabel,
              ),
              minLines: 2,
              maxLines: 4,
            ),
            SizedBox(height: spacing.md),
            PointyDetailSection(
              title: l10n.payrollBulkSelectionSection,
              icon: Icons.groups_outlined,
              child: Column(
                children: [
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    value: _allSelected,
                    onChanged: widget.viewModel.isSaving
                        ? null
                        : (selected) => _toggleAll(selected ?? false),
                    title: Text(l10n.payrollBulkSelectAllEmployees),
                    subtitle: Text(
                      l10n.payrollBulkSelectedCount(
                        selectedCount,
                        widget.run.lines.length,
                      ),
                    ),
                  ),
                  Divider(height: spacing.md),
                  for (final line in widget.run.lines)
                    CheckboxListTile(
                      key: ValueKey('payroll_bulk_line_${line.id}'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      value: _selectedLineIds.contains(line.id),
                      onChanged: widget.viewModel.isSaving
                          ? null
                          : (selected) =>
                                _toggleLine(line.id, selected ?? false),
                      title: Text(
                        payrollEmployeeLineTitle(l10n, line),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        _employeeLineSubtitle(l10n, line),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (showSelectionError) ...[
                    SizedBox(height: spacing.xs),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        l10n.payrollBulkNoEmployeesSelected,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.danger,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(height: spacing.md),
            PointyDetailSection(
              title: l10n.payrollAdjustmentPreviewSection,
              icon: Icons.calculate_outlined,
              child: PointySummaryList(
                rows: [
                  PointySummaryRow(
                    label: l10n.payrollBulkSelectedEmployeesLabel,
                    value: l10n.payrollLineCount(selectedCount),
                  ),
                  PointySummaryRow(
                    label: l10n.payrollBulkAmountPerEmployeeLabel,
                    value: formatMoney(amount),
                  ),
                  PointySummaryRow(
                    label: isDeduction
                        ? l10n.payrollBulkTotalDeductionLabel
                        : l10n.payrollBulkTotalAdditionLabel,
                    value: formatMoney(totalImpact),
                    emphasized: true,
                    dividerAbove: true,
                    valueColor: isDeduction ? colors.danger : colors.success,
                  ),
                ],
              ),
            ),
            SizedBox(height: spacing.md),
            ListenableBuilder(
              listenable: widget.viewModel,
              builder: (context, _) {
                return Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: widget.viewModel.isSaving
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: Text(l10n.cancelButton),
                      ),
                    ),
                    SizedBox(width: spacing.sm),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: widget.viewModel.isSaving ? null : _save,
                        icon: const Icon(Icons.playlist_add_check_outlined),
                        label: Text(l10n.payrollBulkAdjustmentSaveButton),
                      ),
                    ),
                  ],
                );
              },
            ),
            if (widget.viewModel.hasSaveError) ...[
              SizedBox(height: spacing.sm),
              PointyInlineMessage.error(
                message: l10n.payrollBulkAdjustmentSaveError,
              ),
            ],
          ],
        ),
      ),
    );
  }

  bool get _allSelected {
    return widget.run.lines.isNotEmpty &&
        _selectedLineIds.length == widget.run.lines.length;
  }

  Future<void> _save() async {
    setState(() {
      _submitted = true;
    });
    final amount = decimalValue(_amountController.text);
    if (_selectedLineIds.isEmpty || amount <= 0) {
      return;
    }

    final updatedRun = await widget.viewModel.createPayrollBulkAdjustment(
      widget.run,
      PayrollBulkAdjustmentDraft(
        payrollLineIds: [
          for (final line in widget.run.lines)
            if (_selectedLineIds.contains(line.id)) line.id,
        ],
        type: _type,
        amount: decimalPayload(_amountController.text),
        notes: _notesController.text,
      ),
    );
    if (mounted && updatedRun != null) {
      Navigator.of(context).pop(updatedRun);
    } else if (mounted) {
      setState(() {});
    }
  }

  void _toggleAll(bool selected) {
    setState(() {
      _selectedLineIds = selected
          ? widget.run.lines.map((line) => line.id).toSet()
          : <int>{};
    });
  }

  void _toggleLine(int lineId, bool selected) {
    setState(() {
      if (selected) {
        _selectedLineIds.add(lineId);
      } else {
        _selectedLineIds.remove(lineId);
      }
    });
  }

  String _employeeLineSubtitle(AppLocalizations l10n, PayrollLine line) {
    final parts = [
      if (line.employeeNumber.trim().isNotEmpty) line.employeeNumber.trim(),
      payrollLinePayLabel(l10n, line),
      l10n.payrollLineAmountDetail(
        l10n.payrollLineNetLabel,
        formatMoney(line.netAmount),
      ),
    ];
    return parts.join(' - ');
  }

  void _refreshPreview() {
    setState(() {});
  }
}

class _PayrollLineAdjustmentSheet extends StatefulWidget {
  const _PayrollLineAdjustmentSheet({
    required this.run,
    required this.line,
    required this.viewModel,
  });

  final PayrollRun run;
  final PayrollLine line;
  final EmployeePayrollViewModel viewModel;

  @override
  State<_PayrollLineAdjustmentSheet> createState() =>
      _PayrollLineAdjustmentSheetState();
}

class _PayrollLineAdjustmentSheetState
    extends State<_PayrollLineAdjustmentSheet> {
  late final TextEditingController _absenceDaysController;
  late final TextEditingController _overtimeHoursController;
  late final TextEditingController _raiseAmountController;
  late final TextEditingController _manualAdditionController;
  late final TextEditingController _manualDeductionController;
  late final TextEditingController _notesController;

  @override
  void initState() {
    super.initState();
    _absenceDaysController = TextEditingController(
      text: decimalInput(widget.line.absenceDays),
    );
    _overtimeHoursController = TextEditingController(
      text: decimalInput(widget.line.overtimeHours),
    );
    _raiseAmountController = TextEditingController(
      text: decimalInput(widget.line.raiseAmount),
    );
    _manualAdditionController = TextEditingController(
      text: decimalInput(widget.line.manualAdditionAmount),
    );
    _manualDeductionController = TextEditingController(
      text: decimalInput(widget.line.manualDeductionAmount),
    );
    _notesController = TextEditingController(text: widget.line.notes);
    for (final controller in _amountControllers) {
      controller.addListener(_refreshPreview);
    }
  }

  List<TextEditingController> get _amountControllers => [
    _absenceDaysController,
    _overtimeHoursController,
    _raiseAmountController,
    _manualAdditionController,
    _manualDeductionController,
  ];

  @override
  void dispose() {
    for (final controller in _amountControllers) {
      controller
        ..removeListener(_refreshPreview)
        ..dispose();
    }
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final periodDays = payrollPeriodDays(widget.run);
    final absenceDays = decimalValue(_absenceDaysController.text);
    final absenceDeduction = _absenceDeduction;
    final projectedAdditions = _projectedAdditions;
    final projectedDeductions = _projectedDeductions;
    final projectedNet = _projectedNet;
    final hasAbsenceError = periodDays > 0 && absenceDays > periodDays;
    final hasNetError = projectedNet < 0;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            PointySectionHeader(
              title: l10n.payrollLineAdjustmentTitle(
                payrollEmployeeLineTitle(l10n, widget.line),
              ),
              subtitle: l10n.payrollLineAdjustmentSubtitle,
              leading: const Icon(Icons.tune_outlined),
            ),
            SizedBox(height: spacing.md),
            TextFormField(
              controller: _absenceDaysController,
              decoration: InputDecoration(
                labelText: l10n.absenceDaysField,
                helperText: l10n.absenceDaysHelper(
                  formatMoney(_absenceDayRate),
                ),
                errorText: hasAbsenceError
                    ? l10n.absenceDaysExceedPeriodError(periodDays)
                    : null,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [DecimalTextInputFormatter()],
            ),
            SizedBox(height: spacing.sm),
            TextFormField(
              controller: _overtimeHoursController,
              decoration: InputDecoration(
                labelText: l10n.overtimeHoursField,
                helperText: l10n.overtimeHoursHelper(
                  formatMoney(_overtimeHourlyRate),
                  decimalInput(widget.line.overtimeMultiplier),
                ),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [DecimalTextInputFormatter()],
            ),
            SizedBox(height: spacing.sm),
            TextFormField(
              controller: _raiseAmountController,
              decoration: InputDecoration(
                labelText: l10n.raiseAmountField,
                helperText: l10n.raiseAmountHelper,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [DecimalTextInputFormatter()],
            ),
            SizedBox(height: spacing.sm),
            TextFormField(
              controller: _manualAdditionController,
              decoration: InputDecoration(
                labelText: l10n.manualAdditionAmountField,
                helperText: l10n.manualAdditionAmountHelper,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [DecimalTextInputFormatter()],
            ),
            SizedBox(height: spacing.sm),
            TextFormField(
              controller: _manualDeductionController,
              decoration: InputDecoration(
                labelText: l10n.manualDeductionAmountField,
                helperText: l10n.manualDeductionAmountHelper,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [DecimalTextInputFormatter()],
            ),
            SizedBox(height: spacing.sm),
            TextFormField(
              controller: _notesController,
              decoration: InputDecoration(
                labelText: l10n.payrollLineNotesLabel,
              ),
              minLines: 2,
              maxLines: 4,
            ),
            SizedBox(height: spacing.md),
            PointyDetailSection(
              title: l10n.payrollAdjustmentPreviewSection,
              icon: Icons.calculate_outlined,
              child: PointySummaryList(
                rows: [
                  PointySummaryRow(
                    label: l10n.payrollLineGrossLabel,
                    value: formatMoney(widget.line.grossAmount),
                  ),
                  PointySummaryRow(
                    label: l10n.payrollLineAbsenceDeductionLabel,
                    value: formatMoney(absenceDeduction),
                    valueColor: absenceDeduction > 0 ? colors.danger : null,
                  ),
                  PointySummaryRow(
                    label: l10n.payrollLineOvertimePayLabel,
                    value: formatMoney(_overtimeAmount),
                    valueColor: _overtimeAmount > 0 ? colors.success : null,
                  ),
                  PointySummaryRow(
                    label: l10n.payrollLineAdditionsLabel,
                    value: formatMoney(projectedAdditions),
                    valueColor: projectedAdditions > 0 ? colors.success : null,
                  ),
                  PointySummaryRow(
                    label: l10n.payrollLineDeductionsLabel,
                    value: formatMoney(projectedDeductions),
                    valueColor: projectedDeductions > 0 ? colors.danger : null,
                  ),
                  PointySummaryRow(
                    label: l10n.payrollLineProjectedNetLabel,
                    value: formatMoney(projectedNet),
                    emphasized: true,
                    dividerAbove: true,
                    valueColor: hasNetError
                        ? colors.danger
                        : colors.primaryStrong,
                  ),
                ],
              ),
            ),
            if (hasNetError) ...[
              SizedBox(height: spacing.sm),
              PointyInlineMessage.error(
                message: l10n.negativeNetPayrollLineError,
              ),
            ],
            SizedBox(height: spacing.md),
            ListenableBuilder(
              listenable: widget.viewModel,
              builder: (context, _) {
                return Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: widget.viewModel.isSaving
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: Text(l10n.cancelButton),
                      ),
                    ),
                    SizedBox(width: spacing.sm),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed:
                            widget.viewModel.isSaving ||
                                hasAbsenceError ||
                                hasNetError
                            ? null
                            : _save,
                        icon: const Icon(Icons.save_outlined),
                        label: Text(l10n.payrollLineAdjustmentSaveButton),
                      ),
                    ),
                  ],
                );
              },
            ),
            if (widget.viewModel.hasSaveError) ...[
              SizedBox(height: spacing.sm),
              PointyInlineMessage.error(
                message: l10n.payrollLineAdjustmentSaveError,
              ),
            ],
          ],
        ),
      ),
    );
  }

  double get _absenceDayRate {
    if (widget.line.absenceDayRate > 0) {
      return widget.line.absenceDayRate;
    }
    final periodDays = payrollPeriodDays(widget.run);
    if (periodDays <= 0) {
      return 0;
    }
    return widget.line.grossAmount / periodDays;
  }

  double get _absenceDeduction {
    return roundMoney(
      decimalValue(_absenceDaysController.text) * _absenceDayRate,
    );
  }

  double get _overtimeHourlyRate {
    // The backend computes the hourly wage from the employee's plan (day rate
    // divided by standard daily hours); fall back to an 8h day for a fresh line.
    if (widget.line.overtimeHourlyRate > 0) {
      return widget.line.overtimeHourlyRate;
    }
    return _absenceDayRate / 8.0;
  }

  double get _overtimeAmount {
    return roundMoney(
      decimalValue(_overtimeHoursController.text) *
          _overtimeHourlyRate *
          (widget.line.overtimeMultiplier <= 0
              ? 1.5
              : widget.line.overtimeMultiplier),
    );
  }

  double get _projectedAdditions {
    return roundMoney(
      _existingAdjustmentAdditions +
          _overtimeAmount +
          decimalValue(_raiseAmountController.text) +
          decimalValue(_manualAdditionController.text),
    );
  }

  double get _projectedDeductions {
    final fixed =
        _existingAdjustmentDeductions +
        _absenceDeduction +
        decimalValue(_manualDeductionController.text);
    // What the employee owes — staff purchases, a balance on their account —
    // gives way first: the server shrinks it rather than let the line go
    // negative, and what it no longer covers stays owed for the next run. So
    // it counts only up to the pay left over.
    final room = math.max(
      0.0,
      widget.line.grossAmount + _projectedAdditions - fixed,
    );
    return roundMoney(fixed + math.min(_existingDebtDeductions, room));
  }

  double get _projectedNet {
    return roundMoney(
      widget.line.grossAmount + _projectedAdditions - _projectedDeductions,
    );
  }

  double get _existingAdjustmentAdditions {
    return widget.line.adjustments
        .where((adjustment) => adjustment.direction == 'addition')
        .fold<double>(0, (total, adjustment) => total + adjustment.amount);
  }

  double get _existingAdjustmentDeductions {
    return widget.line.adjustments
        .where(
          (adjustment) =>
              adjustment.direction == 'deduction' && !adjustment.isFittedDebt,
        )
        .fold<double>(0, (total, adjustment) => total + adjustment.amount);
  }

  double get _existingDebtDeductions {
    return widget.line.adjustments
        .where((adjustment) => adjustment.isFittedDebt)
        .fold<double>(0, (total, adjustment) => total + adjustment.amount);
  }

  Future<void> _save() async {
    final updatedRun = await widget.viewModel.updatePayrollLineAdjustments(
      widget.run,
      widget.line,
      PayrollLineAdjustmentDraft(
        absenceDays: decimalPayload(_absenceDaysController.text),
        overtimeHours: decimalPayload(_overtimeHoursController.text),
        raiseAmount: decimalPayload(_raiseAmountController.text),
        manualAdditionAmount: decimalPayload(_manualAdditionController.text),
        manualDeductionAmount: decimalPayload(_manualDeductionController.text),
        notes: _notesController.text,
      ),
    );
    if (mounted && updatedRun != null) {
      Navigator.of(context).pop(updatedRun);
    } else if (mounted) {
      setState(() {});
    }
  }

  void _refreshPreview() {
    setState(() {});
  }
}
