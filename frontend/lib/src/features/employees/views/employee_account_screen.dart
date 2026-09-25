import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/balance_entry.dart';
import '../../../data/models/employee.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../contacts/views/balance_entries_section.dart';
import '../view_models/employee_payroll_view_model.dart';
import 'payroll_labels.dart';

/// One employee's account: what they owe the shop and what it owes them —
/// the opening balance they arrived with and every adjustment since — which
/// the next payroll run deducts or pays, or cash settles now.
class EmployeeAccountScreen extends StatefulWidget {
  const EmployeeAccountScreen({
    super.key,
    required this.viewModel,
    required this.employee,
    required this.contactRepository,
    required this.capabilities,
  });

  final EmployeePayrollViewModel viewModel;
  final Employee employee;

  /// Carries the balance entries for every party; an employee is one more.
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;

  @override
  State<EmployeeAccountScreen> createState() => _EmployeeAccountScreenState();
}

class _EmployeeAccountScreenState extends State<EmployeeAccountScreen> {
  @override
  void initState() {
    super.initState();
    // The list row may be minutes old; the account is read fresh.
    widget.viewModel.refreshEmployee(widget.employee.id);
  }

  Future<void> _refresh() async {
    await widget.viewModel.refreshEmployee(widget.employee.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final capabilities = widget.capabilities;

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final employee =
            widget.viewModel.employeeById(widget.employee.id) ??
            widget.employee;
        final balance = employee.accountBalance;
        return Scaffold(
          appBar: AppBar(
            title: Text(employee.fullName),
            actions: [
              IconButton(
                tooltip: l10n.refreshEmployeePayrollTooltip,
                onPressed: _refresh,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: SafeArea(
            child: AdaptiveMaxWidth(
              width: AppContentWidth.detail,
              child: ListView(
                padding: EdgeInsets.all(spacing.lg),
                children: [
                  _EmployeeProfile(employee: employee),
                  if (capabilities.canViewEmployeeBalances) ...[
                    SizedBox(height: spacing.md),
                    _EmployeeAccountSummary(
                      balance: balance ?? const EmployeeAccountBalance(),
                    ),
                    SizedBox(height: spacing.md),
                    BalanceEntriesSection(
                      key: ValueKey('employee_balance_entries_${employee.id}'),
                      repository: widget.contactRepository,
                      party: BalanceParty.employee,
                      partyId: employee.id,
                      canManage: capabilities.canManageEmployeeBalances,
                      canCancel: capabilities.canCancelEmployeeBalances,
                      // Cash moves through the user's own drawer, so it takes
                      // the drawer's own right as well.
                      canSettleInCash:
                          capabilities.canManageEmployeeBalances &&
                          capabilities.canCreateRegisterCashMovement,
                      cashPayable: balance?.owedToEmployee ?? 0,
                      cashCollectable: balance?.owedByEmployee ?? 0,
                      // An entry moves what the next payroll run pays or
                      // deducts; the figures above are read again.
                      onChanged: _refresh,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EmployeeProfile extends StatelessWidget {
  const _EmployeeProfile({required this.employee});

  final Employee employee;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final plan = employee.activeCompensationPlan;
    final details = [
      if (employee.employeeNumber.isNotEmpty) employee.employeeNumber,
      if (employee.jobTitle.isNotEmpty) employee.jobTitle,
      if (employee.department.isNotEmpty) employee.department,
    ];

    return PointyDetailSection(
      title: employee.fullName,
      icon: Icons.badge_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            details.isEmpty ? l10n.employeeNoDetails : details.join(' - '),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              PointyStatusPill(
                label: employeeStatusLabel(l10n, employee.status),
                icon: Icons.circle_outlined,
                color: employeeStatusColor(context, employee.status),
              ),
              if (plan != null)
                PointyStatusPill(
                  label: compensationPlanLabel(l10n, plan),
                  icon: Icons.payments_outlined,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmployeeAccountSummary extends StatelessWidget {
  const _EmployeeAccountSummary({required this.balance});

  final EmployeeAccountBalance balance;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final scheduled =
        balance.scheduledDeduction > 0.005 || balance.scheduledPayment > 0.005;

    return PointyDetailSection(
      title: l10n.employeeAccountTitle,
      icon: Icons.account_balance_wallet_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointyMetricGrid(
            maxColumns: 2,
            minTileWidth: 170,
            gap: PointyMetricGridGap.compact,
            metrics: [
              PointyMetricGridItem(
                label: l10n.employeeAccountOwedByLabel,
                value: formatMoney(balance.owedByEmployee),
                icon: Icons.call_received_rounded,
                accentColor: balance.owedByEmployee > 0.005
                    ? colors.warning
                    : null,
              ),
              PointyMetricGridItem(
                label: l10n.employeeAccountOwedToLabel,
                value: formatMoney(balance.owedToEmployee),
                icon: Icons.call_made_rounded,
                accentColor: balance.owedToEmployee > 0.005
                    ? colors.success
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            scheduled
                ? l10n.employeeAccountNextPayrollValue(
                    formatMoney(balance.scheduledDeduction),
                    formatMoney(balance.scheduledPayment),
                  )
                : l10n.employeeAccountHint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ),
    );
  }
}
