import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/employee.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/employee_payroll_view_model.dart';
import 'employee_loan_review_actions.dart';
import 'employee_loan_row.dart';
import 'employee_loan_sheet.dart';

/// One employee's loans, on their account — and the way to give them another
/// without going back to the shop-wide list to find them again.
class EmployeeLoansSection extends StatefulWidget {
  const EmployeeLoansSection({
    super.key,
    required this.viewModel,
    required this.employee,
    required this.capabilities,
  });

  final EmployeePayrollViewModel viewModel;
  final Employee employee;
  final AuthorizationCapabilities capabilities;

  @override
  State<EmployeeLoansSection> createState() => _EmployeeLoansSectionState();
}

class _EmployeeLoansSectionState extends State<EmployeeLoansSection> {
  List<EmployeeLoan>? _loans;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loans = await widget.viewModel.loansFor(widget.employee.id);
    if (!mounted) {
      return;
    }
    setState(() {
      // A failed refresh keeps the list it had rather than blanking it.
      _loans = loans ?? _loans;
      _failed = loans == null;
    });
  }

  Future<void> _give() async {
    final given = await showEmployeeLoanSheet(
      context,
      viewModel: widget.viewModel,
      capabilities: widget.capabilities,
      employee: widget.employee,
    );
    if (given && mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final capabilities = widget.capabilities;
    final canGive = capabilities.canCreateEmployeeLoans;
    final onPayroll = widget.employee.isOnPayroll;
    final loans = _loans;
    final muted = textTheme.bodyMedium?.copyWith(color: colors.mutedInk);

    return PointyDetailSection(
      title: l10n.employeeLoansSectionTitle,
      icon: Icons.account_balance_wallet_outlined,
      trailing: canGive && onPayroll
          ? FilledButton.tonalIcon(
              key: const ValueKey('employee_account_new_loan'),
              onPressed: widget.viewModel.isSaving ? null : _give,
              icon: const Icon(Icons.add),
              label: Text(l10n.newEmployeeLoanTitle),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (loans == null && !_failed)
            const PointyLoadingArea(minHeight: 72, progressSize: 22)
          else if (loans == null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.employeeLoansLoadError,
                    style: textTheme.bodyMedium?.copyWith(color: colors.danger),
                  ),
                ),
                TextButton(
                  key: const ValueKey('employee_account_loans_retry'),
                  onPressed: _load,
                  child: Text(l10n.retryButton),
                ),
              ],
            )
          else if (loans.isEmpty)
            Text(l10n.employeeNoLoans, style: muted)
          else
            for (final loan in loans) ...[
              EmployeeLoanRow(
                loan: loan,
                showEmployee: false,
                actions: [
                  if (capabilities.canManageEmployeeLoans &&
                      loan.status.canReview)
                    EmployeeLoanReviewActions(
                      keyPrefix: 'account_loan',
                      loan: loan,
                      isSaving: widget.viewModel.isSaving,
                      onApprove: (disbursement) => _approve(loan, disbursement),
                      onReject: () => _reject(loan),
                    ),
                ],
              ),
              // Each row is framed already; a divider would draw the line twice.
              if (loan != loans.last) SizedBox(height: spacing.sm),
            ],
          if (canGive && !onPayroll) ...[
            SizedBox(height: spacing.sm),
            Text(
              l10n.employeeLoansOffPayrollNote,
              key: const ValueKey('employee_account_off_payroll_note'),
              style: muted,
            ),
          ],
        ],
      ),
    );
  }

  Future<Exception?> _approve(
    EmployeeLoan loan,
    LoanDisbursement disbursement,
  ) async {
    final failure = await widget.viewModel.approveLoan(
      loan,
      disbursement: disbursement,
    );
    if (failure == null && mounted) {
      await _load();
    }
    return failure;
  }

  Future<void> _reject(EmployeeLoan loan) async {
    await widget.viewModel.rejectLoan(loan);
    if (mounted) {
      await _load();
    }
  }
}
