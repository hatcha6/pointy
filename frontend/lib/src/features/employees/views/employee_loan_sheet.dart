import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/employee.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../treasury/view_models/bank_routing.dart';
import '../view_models/employee_payroll_view_model.dart';
import 'employee_picker_sheet.dart';
import 'loan_disbursement_picker.dart';
import 'payroll_labels.dart';

typedef _LoanOutcome = ({String employeeName, double amount, bool handedOver});

/// Opens the form that lends an employee money: [employee] when whose loan it
/// is was already decided — from their account — otherwise the form asks.
/// Says what happened once the loan is recorded or handed over, and resolves
/// true then.
Future<bool> showEmployeeLoanSheet(
  BuildContext context, {
  required EmployeePayrollViewModel viewModel,
  required AuthorizationCapabilities capabilities,
  Employee? employee,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final outcome = await showAdaptiveFormSurface<_LoanOutcome>(
    context: context,
    size: AdaptiveModalSize.standard,
    title: l10n.newEmployeeLoanTitle,
    builder: (_) => EmployeeLoanForm(
      viewModel: viewModel,
      capabilities: capabilities,
      employee: employee,
    ),
  );
  if (outcome == null) {
    return false;
  }
  messenger?.showSnackBar(
    SnackBar(
      content: Text(
        outcome.handedOver
            ? l10n.loanGrantedSnack(
                outcome.employeeName,
                formatMoney(outcome.amount),
              )
            : l10n.loanRecordedSnack(outcome.employeeName),
      ),
    ),
  );
  return true;
}

/// A loan the owner gives, or records for someone else to approve.
///
/// Asks whose it is, how much and how fast payroll takes it back, and — for
/// someone who may approve loans — whether the money is handed over now and
/// from where. Around those it says what the person needs to decide well:
/// what the employee already owes on earlier loans, a request of theirs still
/// waiting, a pay plan payroll could not deduct from, an instalment bigger
/// than the wage it comes out of.
class EmployeeLoanForm extends StatefulWidget {
  const EmployeeLoanForm({
    super.key,
    required this.viewModel,
    required this.capabilities,
    this.employee,
  });

  final EmployeePayrollViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  /// Fixes whose loan it is; the form then offers no other.
  final Employee? employee;

  @override
  State<EmployeeLoanForm> createState() => _EmployeeLoanFormState();
}

class _EmployeeLoanFormState extends State<EmployeeLoanForm> {
  /// A whole-salary advance, and the spreads a shop actually agrees to.
  static const _monthChoices = [1, 2, 3, 6, 12];

  final _amountController = TextEditingController();
  final _monthlyController = TextEditingController();
  final _purposeController = TextEditingController();
  final _amountFocus = FocusNode();
  final _monthlyFocus = FocusNode();
  final _disbursement = LoanDisbursementController();
  final _errorKey = GlobalKey();

  Employee? _employee;
  List<EmployeeLoan>? _employeeLoans;
  int _contextTicket = 0;

  /// The spread the person tapped, kept while they correct the amount so the
  /// instalment follows it rather than the loan quietly lengthening.
  int? _pickedMonths;
  bool _handOverNow = true;
  bool _submitted = false;
  bool _saving = false;
  String? _error;

  bool get _canHandOver => widget.capabilities.canApproveEmployeeLoans;
  bool get _handsOver => _canHandOver && _handOverNow;
  double get _amount => decimalValue(_amountController.text);
  double get _monthly => decimalValue(_monthlyController.text);

  @override
  void initState() {
    super.initState();
    final employee = widget.employee;
    if (employee != null) {
      _employee = employee;
      _loadContext(employee);
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _monthlyController.dispose();
    _purposeController.dispose();
    _amountFocus.dispose();
    _monthlyFocus.dispose();
    _disbursement.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final repayment = LoanRepayment.of(_amount, _monthly);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.newEmployeeLoanSubtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                  SizedBox(height: spacing.md),
                  PointySectionHeader(title: l10n.loanEmployeeLabel),
                  _EmployeeField(
                    employee: _employee,
                    locked: widget.employee != null,
                    hasError: _submitted && _employee == null,
                    enabled: !_saving,
                    onPick: _pickEmployee,
                  ),
                  AnimatedSize(
                    duration: PointyMotion.standard,
                    curve: PointyMotion.curve,
                    alignment: AlignmentDirectional.topCenter,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _employeeNotes(l10n, spacing),
                    ),
                  ),
                  SizedBox(height: spacing.lg),
                  PointySectionHeader(title: l10n.loanTermsSection),
                  ..._terms(l10n, spacing, repayment),
                  SizedBox(height: spacing.lg),
                  ..._handOver(l10n, spacing),
                  if (_error != null) ...[
                    SizedBox(height: spacing.md),
                    PointyInlineMessage.error(key: _errorKey, message: _error!),
                  ],
                ],
              ),
            ),
          ),
          PointyStickyActionFooter(
            padding: EdgeInsetsDirectional.fromSTEB(
              20,
              spacing.sm,
              20,
              spacing.sm,
            ),
            summary: _amount > 0
                ? _FooterSummary(amount: _amount, repayment: repayment)
                : null,
            primaryAction: FilledButton.icon(
              key: const ValueKey('employee_loan_submit'),
              onPressed: _saving ? null : _submit,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : Icon(
                      _handsOver
                          ? Icons.payments_outlined
                          : Icons.save_outlined,
                    ),
              label: Text(
                _handsOver ? l10n.loanGrantButton : l10n.loanRecordButton,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// What the person should know about this employee before lending more.
  List<Widget> _employeeNotes(AppLocalizations l10n, AdaptiveSpacing spacing) {
    final employee = _employee;
    if (employee == null) {
      return const [];
    }
    final loans = _employeeLoans ?? const <EmployeeLoan>[];
    final pending = [
      for (final loan in loans)
        if (loan.status == EmployeeLoanStatus.requested) loan,
    ];
    final open = [
      for (final loan in loans)
        if (loan.status == EmployeeLoanStatus.approved &&
            loan.outstandingBalance > 0.005)
          loan,
    ];
    double total(Iterable<double> values) =>
        values.fold(0, (sum, value) => sum + value);

    final notes = [
      if (employee.activeCompensationPlan == null)
        PointyInlineMessage.warning(
          key: const ValueKey('employee_loan_no_plan_note'),
          message: l10n.loanContextNoPlanWarning,
          compact: true,
        ),
      if (pending.isNotEmpty)
        PointyDetailCallout(
          key: const ValueKey('employee_loan_pending_note'),
          icon: Icons.hourglass_top_outlined,
          tone: PointyCalloutTone.warning,
          title: l10n.loanContextPendingTitle(
            pending.length,
            formatMoney(total(pending.map((loan) => loan.amount))),
          ),
          message: l10n.loanContextPendingMessage,
        ),
      if (open.isNotEmpty)
        PointyDetailCallout(
          key: const ValueKey('employee_loan_open_note'),
          icon: Icons.account_balance_wallet_outlined,
          title: l10n.loanContextOpenTitle(
            open.length,
            formatMoney(total(open.map((loan) => loan.outstandingBalance))),
          ),
          message: l10n.loanContextOpenMessage(
            formatMoney(total(open.map((loan) => loan.monthlyDeduction))),
          ),
        ),
    ];
    return [
      for (final note in notes) ...[SizedBox(height: spacing.sm), note],
    ];
  }

  List<Widget> _terms(
    AppLocalizations l10n,
    AdaptiveSpacing spacing,
    LoanRepayment? repayment,
  ) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final amount = _amount;
    final monthly = _monthly;
    // Too high is said as soon as it is true; missing, only once they tried.
    final String? monthlyError;
    if (amount > 0 && monthly > amount + 0.005) {
      monthlyError = l10n.loanMonthlyDeductionTooHigh;
    } else if (_submitted && monthly <= 0) {
      monthlyError = l10n.positiveAmountRequiredError;
    } else {
      monthlyError = null;
    }
    final salary = _monthlySalary(_employee);

    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('employee_loan_amount'),
              controller: _amountController,
              focusNode: _amountFocus,
              autofocus: widget.employee != null,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [DecimalTextInputFormatter()],
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l10n.loanAmountLabel,
                errorText: _submitted && amount <= 0
                    ? l10n.positiveAmountRequiredError
                    : null,
                errorMaxLines: 3,
              ),
              onChanged: _onAmountChanged,
              onSubmitted: (_) => _monthlyFocus.requestFocus(),
            ),
          ),
          SizedBox(width: spacing.sm),
          Expanded(
            child: TextField(
              key: const ValueKey('employee_loan_monthly'),
              controller: _monthlyController,
              focusNode: _monthlyFocus,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [DecimalTextInputFormatter()],
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l10n.loanMonthlyDeductionLabel,
                errorText: monthlyError,
                errorMaxLines: 3,
              ),
              // Typed by hand: the instalment is theirs now, not a spread's.
              onChanged: (_) => setState(() => _pickedMonths = null),
            ),
          ),
        ],
      ),
      SizedBox(height: spacing.sm),
      Text(
        l10n.loanRepayOverLabel,
        style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
      ),
      SizedBox(height: spacing.xs),
      // On a row of their own and compact, so all five fit a phone's width.
      Wrap(
        spacing: spacing.xs,
        runSpacing: spacing.xs,
        children: [
          for (final months in _monthChoices)
            ChoiceChip(
              key: ValueKey('employee_loan_months_$months'),
              visualDensity: VisualDensity.compact,
              labelPadding: const EdgeInsets.symmetric(horizontal: 6),
              // The fill says which is chosen; a checkmark would widen the
              // chip and reflow the row under the person's finger.
              showCheckmark: false,
              label: Text(l10n.loanMonthsChip(months)),
              selected:
                  amount > 0 &&
                  (monthly - LoanRepayment.instalmentFor(amount, months))
                          .abs() <
                      0.005,
              onSelected: amount > 0 && !_saving
                  ? (_) => _pickMonths(months)
                  : null,
            ),
        ],
      ),
      if (repayment != null) ...[
        SizedBox(height: spacing.sm),
        _RepaymentLine(repayment: repayment),
      ],
      if (salary != null && monthly > salary + 0.005) ...[
        SizedBox(height: spacing.sm),
        PointyInlineMessage.warning(
          key: const ValueKey('employee_loan_above_salary_note'),
          message: l10n.loanInstalmentAboveSalaryWarning(formatMoney(salary)),
          compact: true,
        ),
      ],
      SizedBox(height: spacing.md),
      TextField(
        key: const ValueKey('employee_loan_purpose'),
        controller: _purposeController,
        enabled: !_saving,
        minLines: 1,
        maxLines: 2,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(labelText: l10n.loanNoteLabel),
        onSubmitted: (_) => _submit(),
      ),
    ];
  }

  List<Widget> _handOver(AppLocalizations l10n, AdaptiveSpacing spacing) {
    if (!_canHandOver) {
      return [
        PointyInlineMessage(
          key: const ValueKey('employee_loan_request_only_note'),
          icon: Icons.schedule_outlined,
          message: l10n.loanRequestOnlyNote,
          compact: true,
        ),
      ];
    }
    return [
      PointySectionHeader(title: l10n.loanHandOverSection),
      SegmentedButton<bool>(
        key: const ValueKey('employee_loan_hand_over'),
        showSelectedIcon: false,
        segments: [
          ButtonSegment(
            value: true,
            icon: const Icon(Icons.payments_outlined),
            label: Text(l10n.loanHandOverNow),
          ),
          ButtonSegment(
            value: false,
            icon: const Icon(Icons.schedule_outlined),
            label: Text(l10n.loanHandOverLater),
          ),
        ],
        selected: {_handOverNow},
        onSelectionChanged: _saving
            ? null
            : (selection) => setState(() => _handOverNow = selection.first),
      ),
      SizedBox(height: spacing.md),
      AnimatedSize(
        duration: PointyMotion.standard,
        curve: PointyMotion.curve,
        alignment: AlignmentDirectional.topCenter,
        child: _handOverNow
            ? LoanDisbursementPicker(
                controller: _disbursement,
                enabled: !_saving,
              )
            : PointyInlineMessage(
                key: const ValueKey('employee_loan_later_note'),
                icon: Icons.schedule_outlined,
                message: l10n.loanHandOverLaterNote,
                compact: true,
              ),
      ),
    ];
  }

  /// The monthly wage an instalment comes out of — only where the plan is a
  /// fixed monthly salary, the one case where that is a single known figure.
  static double? _monthlySalary(Employee? employee) {
    final plan = employee?.activeCompensationPlan;
    if (plan == null || plan.amount <= 0) {
      return null;
    }
    final monthlyFixed =
        plan.salaryType == SalaryType.monthlyFixed ||
        (plan.salaryType == null && plan.payType == PayType.monthlySalary);
    return monthlyFixed ? plan.amount : null;
  }

  void _onAmountChanged(String _) {
    final months = _pickedMonths;
    if (months != null) {
      final amount = _amount;
      _monthlyController.text = amount > 0
          ? decimalInput(LoanRepayment.instalmentFor(amount, months))
          : '';
    }
    setState(() {});
  }

  void _pickMonths(int months) {
    setState(() {
      _pickedMonths = months;
      _monthlyController.text = decimalInput(
        LoanRepayment.instalmentFor(_amount, months),
      );
    });
  }

  Future<void> _pickEmployee() async {
    final picked = await showEmployeePickerSheet(
      context,
      loadPage: (search, page) =>
          widget.viewModel.searchEmployees(search: search, page: page),
      selectedId: _employee?.id,
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _employee = picked;
      _error = null;
      _loadContext(picked);
    });
    if (_amountController.text.trim().isEmpty) {
      _amountFocus.requestFocus();
    }
  }

  /// Reads what [employee] already owes and has asked for. A later pick wins
  /// over an earlier one still loading.
  void _loadContext(Employee employee) {
    final ticket = ++_contextTicket;
    _employeeLoans = null;
    if (!widget.capabilities.canViewEmployeeLoans) {
      return;
    }
    widget.viewModel.loansFor(employee.id).then((loans) {
      if (!mounted || ticket != _contextTicket) {
        return;
      }
      setState(() => _employeeLoans = loans);
    });
  }

  Future<void> _submit() async {
    if (_saving) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _submitted = true;
      _error = null;
    });
    final employee = _employee;
    final amount = _amount;
    final monthly = _monthly;
    if (employee == null) {
      return;
    }
    if (amount <= 0) {
      _amountFocus.requestFocus();
      return;
    }
    if (monthly <= 0 || monthly > amount + 0.005) {
      _monthlyFocus.requestFocus();
      return;
    }
    final handOver = _handsOver
        ? _disbursement.disbursementFor(BankRoutingScope.accountsOf(context))
        : null;

    setState(() => _saving = true);
    final failure = await widget.viewModel.giveLoan(
      EmployeeLoanDraft(
        employeeId: employee.id,
        amount: decimalInput(amount),
        monthlyDeduction: decimalInput(monthly),
        purpose: _purposeController.text,
      ),
      handOver: handOver,
    );
    if (!mounted) {
      return;
    }
    if (failure == null) {
      final _LoanOutcome outcome = (
        employeeName: employee.fullName,
        amount: amount,
        handedOver: handOver != null,
      );
      Navigator.of(context).pop(outcome);
      return;
    }
    setState(() {
      _saving = false;
      _error = loanFailureMessage(l10n, failure, fallback: l10n.loanSaveError);
    });
    // The refusal sits under the last section; bring it into view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final errorContext = _errorKey.currentContext;
      if (errorContext != null) {
        Scrollable.ensureVisible(
          errorContext,
          duration: PointyMotion.standard,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    });
  }
}

/// Whose loan it is: a button that opens the staff list until someone is
/// chosen, then the chosen employee with what the loan is weighed against —
/// their pay plan and whether they are on leave.
class _EmployeeField extends StatelessWidget {
  const _EmployeeField({
    required this.employee,
    required this.locked,
    required this.hasError,
    required this.enabled,
    required this.onPick,
  });

  final Employee? employee;
  final bool locked;
  final bool hasError;
  final bool enabled;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final employee = this.employee;
    final tappable = enabled && !locked;
    final radius = BorderRadius.circular(PointyRadii.input);

    final Widget content;
    if (employee == null) {
      content = Row(
        children: [
          CircleAvatar(
            backgroundColor: colors.subtleFill,
            foregroundColor: hasError ? colors.danger : colors.mutedInk,
            child: const Icon(Icons.person_search_outlined),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n.loanEmployeePlaceholder,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: hasError ? colors.danger : colors.mutedInk,
              ),
            ),
          ),
          Icon(Icons.expand_more, color: colors.mutedInk),
        ],
      );
    } else {
      final plan = employee.activeCompensationPlan;
      final details = [
        if (employee.employeeNumber.isNotEmpty) employee.employeeNumber,
        if (employee.jobTitle.isNotEmpty) employee.jobTitle,
      ];
      content = Row(
        children: [
          EmployeeInitialAvatar(name: employee.fullName),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  employee.fullName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (details.isNotEmpty)
                  Text(
                    details.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                if (plan != null ||
                    employee.status != EmployeeStatus.active) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (plan != null)
                        PointyStatusPill(
                          label: compensationPlanLabel(l10n, plan),
                          icon: Icons.payments_outlined,
                        ),
                      if (employee.status != EmployeeStatus.active)
                        PointyStatusPill(
                          label: employeeStatusLabel(l10n, employee.status),
                          icon: Icons.circle_outlined,
                          color: employeeStatusColor(context, employee.status),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (!locked) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: tappable ? onPick : null,
              child: Text(l10n.changeContactAction),
            ),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: colors.surface,
          borderRadius: radius,
          child: InkWell(
            key: const ValueKey('employee_loan_employee_field'),
            borderRadius: radius,
            onTap: tappable ? onPick : null,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(
                  color: hasError ? colors.danger : colors.line,
                  width: hasError ? 1.5 : 1,
                ),
              ),
              child: content,
            ),
          ),
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 12, top: 6),
            child: Text(
              l10n.loanEmployeeRequiredError,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
            ),
          ),
      ],
    );
  }
}

/// How payroll takes the loan back, in one sentence.
class _RepaymentLine extends StatelessWidget {
  const _RepaymentLine({required this.repayment});

  final LoanRepayment repayment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final monthly = formatMoney(repayment.monthlyDeduction);
    final text = repayment.hasSmallerLast
        ? l10n.loanRepaymentSummaryWithLast(
            repayment.months,
            monthly,
            formatMoney(repayment.lastInstalment),
          )
        : l10n.loanRepaymentSummary(repayment.months, monthly);

    return Row(
      key: const ValueKey('employee_loan_repayment'),
      children: [
        Icon(
          Icons.event_repeat_outlined,
          size: 18,
          color: colors.primaryStrong,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    );
  }
}

/// The figure the button is about to act on, so a slip of a zero is seen
/// before the money moves.
class _FooterSummary extends StatelessWidget {
  const _FooterSummary({required this.amount, required this.repayment});

  final double amount;
  final LoanRepayment? repayment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final repayment = this.repayment;

    return Wrap(
      key: const ValueKey('employee_loan_summary'),
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          formatMoney(amount),
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        if (repayment != null)
          Text(
            l10n.loanSummaryInstalments(repayment.months),
            style: theme.textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
          ),
      ],
    );
  }
}
