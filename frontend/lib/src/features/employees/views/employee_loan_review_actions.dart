import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/employee.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';

/// The reject/approve pair shown against a loan request awaiting a decision.
///
/// Both decisions are one-way: only a `requested` loan can be reviewed, so
/// neither screen offers a route back once the status flips. The two buttons
/// also sit next to each other in a dense row, where the wrong one is one
/// mis-tap away. Each therefore asks first, naming the employee, the amount,
/// and — for approval — the monthly deduction the decision commits payroll to.
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

  /// Called only after the manager confirms the approval.
  final VoidCallback onApprove;

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
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => PointyConfirmationDialog(
        icon: Icons.verified_outlined,
        title: l10n.approveEmployeeLoanConfirmTitle,
        message: l10n.approveEmployeeLoanConfirmMessage(
          loan.employeeName,
          formatMoney(loan.amount),
          formatMoney(loan.monthlyDeduction),
        ),
        confirmLabel: l10n.employeeLoanApproveButton,
      ),
    );
    if (confirmed == true) {
      onApprove();
    }
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
