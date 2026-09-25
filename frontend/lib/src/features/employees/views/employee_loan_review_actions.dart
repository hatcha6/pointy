import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/employee.dart';
import '../../../data/services/api_error_detail.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/payments/bank_account_picker.dart';
import '../../../shared/responsive/responsive.dart';
import '../../treasury/view_models/bank_routing.dart';

/// The reject/approve pair shown against a loan request awaiting a decision.
///
/// Both decisions are one-way: only a `requested` loan can be reviewed, so
/// neither screen offers a route back once the status flips. The two buttons
/// also sit next to each other in a dense row, where the wrong one is one
/// mis-tap away. Each therefore asks first, naming the employee, the amount,
/// and — for approval — the monthly deduction the decision commits payroll to.
///
/// Approving is handing the money over, so it also asks where the money comes
/// from: the approver's own drawer, the cash box, or a bank transfer.
class EmployeeLoanReviewActions extends StatelessWidget {
  const EmployeeLoanReviewActions({
    super.key,
    required this.loan,
    required this.isSaving,
    required this.onApprove,
    required this.onReject,
    this.keyPrefix = 'loan',
  });

  final EmployeeLoan loan;

  /// Namespaces the button keys, so the payroll attention card and the loans
  /// list stay individually addressable when both are in the tree.
  final String keyPrefix;

  /// Disables both buttons while another payroll write is in flight, so a
  /// decision cannot be submitted twice.
  final bool isSaving;

  /// Called only after the manager confirms the approval, with where the
  /// money comes from. Answers null on success, or why it was refused — the
  /// dialog stays open and says so.
  final Future<Exception?> Function(LoanDisbursement disbursement) onApprove;

  /// Called only after the manager confirms the rejection.
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    return Wrap(
      spacing: spacing.xs,
      runSpacing: spacing.xs,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton(
          key: ValueKey('${keyPrefix}_reject_${loan.id}'),
          onPressed: isSaving ? null : () => _confirmReject(context),
          style: TextButton.styleFrom(foregroundColor: colors.danger),
          child: Text(l10n.employeeLoanRejectButton),
        ),
        FilledButton.tonal(
          key: ValueKey('${keyPrefix}_approve_${loan.id}'),
          onPressed: isSaving ? null : () => _confirmApprove(context),
          child: Text(l10n.employeeLoanApproveButton),
        ),
      ],
    );
  }

  Future<void> _confirmApprove(BuildContext context) async {
    await showLoanApprovalDialog(context, loan: loan, onApprove: onApprove);
  }

  Future<void> _confirmReject(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => PointyDestructiveConfirmationDialog(
        icon: Icons.person_off_outlined,
        title: l10n.rejectEmployeeLoanConfirmTitle,
        message: l10n.rejectEmployeeLoanConfirmMessage(
          loan.employeeName,
          formatMoney(loan.amount),
        ),
        confirmLabel: l10n.employeeLoanRejectButton,
      ),
    );
    if (confirmed == true) {
      onReject();
    }
  }
}

/// Asks for the approval of [loan] and where its money comes from, then
/// approves it through [onApprove]. Stays open on a refusal, saying why.
/// Resolves true once the loan was approved.
Future<bool> showLoanApprovalDialog(
  BuildContext context, {
  required EmployeeLoan loan,
  required Future<Exception?> Function(LoanDisbursement disbursement) onApprove,
}) async {
  final approved = await showDialog<bool>(
    context: context,
    builder: (_) => _LoanApprovalDialog(loan: loan, onApprove: onApprove),
  );
  return approved ?? false;
}

class _LoanApprovalDialog extends StatefulWidget {
  const _LoanApprovalDialog({required this.loan, required this.onApprove});

  final EmployeeLoan loan;
  final Future<Exception?> Function(LoanDisbursement disbursement) onApprove;

  @override
  State<_LoanApprovalDialog> createState() => _LoanApprovalDialogState();
}

class _LoanApprovalDialogState extends State<_LoanApprovalDialog> {
  LoanDisbursementSource _source = LoanDisbursementSource.cashBox;
  int? _bankAccountId;
  bool _bankAccountTouched = false;
  bool _isSaving = false;
  String? _error;

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final accounts = BankRoutingScope.accountsOf(context);
    setState(() {
      _isSaving = true;
      _error = null;
    });
    final failure = await widget.onApprove(
      LoanDisbursement(
        source: _source,
        moneyAccountId: _source == LoanDisbursementSource.bank
            ? (_bankAccountTouched
                  ? _bankAccountId
                  : BankAccountPicker.initialSelection(accounts))
            : null,
      ),
    );
    if (!mounted) {
      return;
    }
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _isSaving = false;
      _error = _failureMessage(l10n, failure);
    });
  }

  String _failureMessage(AppLocalizations l10n, Exception failure) {
    if (apiErrorCode(failure) == 'register_session_required') {
      return l10n.loanApproveSessionRequiredError;
    }
    if (apiStatusCode(failure) == 403) {
      return l10n.loanApprovePermissionError;
    }
    return l10n.loanApproveError;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final accounts = BankRoutingScope.accountsOf(context);
    final loan = widget.loan;

    return AlertDialog(
      icon: const Icon(Icons.verified_outlined),
      title: Text(l10n.approveEmployeeLoanConfirmTitle),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.approveEmployeeLoanConfirmMessage(
                  loan.employeeName,
                  formatMoney(loan.amount),
                  formatMoney(loan.monthlyDeduction),
                ),
              ),
              SizedBox(height: spacing.md),
              Text(
                l10n.loanDisbursementSourceLabel,
                style: textTheme.titleSmall,
              ),
              SizedBox(height: spacing.xs),
              for (final source in LoanDisbursementSource.values)
                _SourceOption(
                  key: ValueKey('loan_source_${source.name}'),
                  title: _sourceLabel(l10n, source),
                  hint: _sourceHint(l10n, source),
                  icon: _sourceIcon(source),
                  selected: _source == source,
                  enabled: !_isSaving,
                  onTap: () => setState(() => _source = source),
                ),
              if (_source == LoanDisbursementSource.bank &&
                  BankAccountPicker.isUseful(accounts)) ...[
                SizedBox(height: spacing.sm),
                BankAccountPicker(
                  accounts: accounts,
                  selectedId: _bankAccountTouched
                      ? _bankAccountId
                      : BankAccountPicker.initialSelection(accounts),
                  enabled: !_isSaving,
                  dense: true,
                  onChanged: (id) => setState(() {
                    _bankAccountTouched = true;
                    _bankAccountId = id;
                  }),
                ),
              ],
              if (_error != null) ...[
                SizedBox(height: spacing.sm),
                PointyInlineMessage.error(message: _error!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancelButton),
        ),
        FilledButton.icon(
          key: const ValueKey('loan_approve_confirm'),
          onPressed: _isSaving ? null : _submit,
          icon: _isSaving
              ? const SizedBox.square(
                  dimension: 18,
                  child: PointySpinner(strokeWidth: 2),
                )
              : const Icon(Icons.verified_outlined),
          label: Text(l10n.employeeLoanApproveButton),
        ),
      ],
    );
  }

  static String _sourceLabel(
    AppLocalizations l10n,
    LoanDisbursementSource source,
  ) {
    return switch (source) {
      LoanDisbursementSource.drawer => l10n.loanSourceDrawer,
      LoanDisbursementSource.cashBox => l10n.loanSourceCashBox,
      LoanDisbursementSource.bank => l10n.loanSourceBank,
    };
  }

  static String _sourceHint(
    AppLocalizations l10n,
    LoanDisbursementSource source,
  ) {
    return switch (source) {
      LoanDisbursementSource.drawer => l10n.loanSourceDrawerHint,
      LoanDisbursementSource.cashBox => l10n.loanSourceCashBoxHint,
      LoanDisbursementSource.bank => l10n.loanSourceBankHint,
    };
  }

  static IconData _sourceIcon(LoanDisbursementSource source) {
    return switch (source) {
      LoanDisbursementSource.drawer => Icons.point_of_sale_outlined,
      LoanDisbursementSource.cashBox => Icons.inventory_2_outlined,
      LoanDisbursementSource.bank => Icons.account_balance_outlined,
    };
  }
}

class _SourceOption extends StatelessWidget {
  const _SourceOption({
    super.key,
    required this.title,
    required this.hint,
    required this.icon,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String title;
  final String hint;
  final IconData icon;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      enabled: enabled,
      selected: selected,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(hint),
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? colors.primary : colors.mutedInk,
      ),
      onTap: onTap,
    );
  }
}
