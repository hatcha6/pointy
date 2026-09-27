import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/employee.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import 'payroll_labels.dart';

/// One loan in a list: what is left of it, how payroll takes it back and
/// where its money came from, with [actions] — the approve/reject pair while
/// it is still a request.
///
/// [showEmployee] names whose it is, for the shop-wide list; one employee's
/// own list leads with the amount instead.
class EmployeeLoanRow extends StatelessWidget {
  const EmployeeLoanRow({
    super.key,
    required this.loan,
    this.showEmployee = true,
    this.actions = const [],
  });

  final EmployeeLoan loan;
  final bool showEmployee;
  final List<Widget> actions;

  /// Handed over and still being repaid: the only loans whose balance says
  /// anything. A request has had nothing lent against it yet, and a repaid
  /// loan's zero is what its status already says.
  bool get _hasBalance => loan.status == EmployeeLoanStatus.approved;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final purpose = loan.purpose.trim();
    final createdAt = loan.createdAt;
    final subtitleParts = showEmployee
        ? [
            if (loan.employeeNumber.isNotEmpty) loan.employeeNumber,
            l10n.employeeLoanAmountDetail(formatMoney(loan.amount)),
            if (purpose.isNotEmpty) purpose,
          ]
        : [
            if (createdAt != null) formatDate(createdAt),
            if (purpose.isNotEmpty) purpose,
          ];

    return PointyDataRow(
      key: ValueKey('employee_loan_row_${loan.id}'),
      leading: CircleAvatar(
        child: Icon(
          showEmployee
              ? Icons.account_balance_wallet_outlined
              : loanStatusIcon(loan.status),
        ),
      ),
      title: showEmployee ? loan.employeeName : formatMoney(loan.amount),
      subtitle: subtitleParts.isEmpty ? null : subtitleParts.join(' - '),
      trailing: showEmployee && _hasBalance
          ? Text(
              formatMoney(loan.outstandingBalance),
              style: Theme.of(context).textTheme.titleMedium,
            )
          : null,
      badges: [
        PointyStatusPill(
          label: loanStatusLabel(l10n, loan.status),
          icon: loanStatusIcon(loan.status),
          color: loanStatusColor(context, loan.status),
        ),
        if (!showEmployee && _hasBalance)
          PointyStatusPill(
            label: l10n.employeeLoanOutstandingDetail(
              formatMoney(loan.outstandingBalance),
            ),
            icon: Icons.hourglass_bottom_outlined,
          ),
        PointyStatusPill(
          label: l10n.employeeLoanMonthlyDeductionDetail(
            formatMoney(loan.monthlyDeduction),
          ),
          icon: Icons.event_repeat_outlined,
        ),
        if (loan.disbursedAt != null)
          PointyStatusPill(
            label: _disbursementLabel(l10n),
            icon: loan.disbursementMethod == 'transfer'
                ? Icons.account_balance_outlined
                : Icons.payments_outlined,
          ),
      ],
      actions: actions,
    );
  }

  /// Where the loan's money came from when it was handed over.
  String _disbursementLabel(AppLocalizations l10n) {
    if (loan.disbursementMethod == 'transfer') {
      return loan.moneyAccountName.isEmpty
          ? l10n.loanDisbursedBankDefault
          : l10n.loanDisbursedBankValue(loan.moneyAccountName);
    }
    return loan.paidFromRegister
        ? l10n.loanDisbursedDrawerValue
        : l10n.loanDisbursedCashValue;
  }
}
