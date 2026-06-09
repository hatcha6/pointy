import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/employee.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/user_repository.dart';
import '../../../core/result.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/async_selection/async_selection.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/employee_payroll_view_model.dart';

class EmployeePayrollScreen extends StatelessWidget {
  const EmployeePayrollScreen({
    super.key,
    required this.viewModel,
    required this.userRepository,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenInvoices,
    required this.onOpenCatalog,
    required this.onOpenCategories,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDashboard,
    this.onOpenDiscounts,
    this.onOpenReports,
    this.onOpenActivityLog,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final EmployeePayrollViewModel viewModel;
  final UserRepository userRepository;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenInvoices;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenCategories;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDashboard;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenReports;
  final VoidCallback? onOpenActivityLog;
  final VoidCallback? onOpenUsers;
  final VoidCallback? onOpenShopSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.employees,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenDashboard: onOpenDashboard,
            onOpenPos: onOpenPos,
            onOpenInvoices: onOpenInvoices,
            onOpenPurchasing: onOpenPurchasing,
            onOpenContacts: onOpenContacts,
            onOpenCatalog: onOpenCatalog,
            onOpenCategories: onOpenCategories,
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenDeviceSettings: onOpenDeviceSettings,
            onOpenDiscounts: onOpenDiscounts,
            onOpenReports: onOpenReports,
            onOpenActivityLog: onOpenActivityLog,
            onOpenEmployees: () {},
            onOpenUsers: onOpenUsers,
            onOpenShopSettings: onOpenShopSettings,
            onLogout: onLogout,
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

    return DefaultTabController(
      length: 3,
      child: Padding(
        padding: spacing.pagePadding,
        child: AdaptiveMaxWidth(
          width: AppContentWidth.workspace,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PointySectionHeader(
                title: l10n.employeePayrollOverviewTitle,
                subtitle: l10n.employeePayrollOverviewSubtitle,
                leading: const Icon(Icons.badge_outlined),
                actions: [
                  FilledButton.icon(
                    onPressed:
                        capabilities.canManageEmployees && !viewModel.isSaving
                        ? () => _showCreateEmployeeSheet(context)
                        : null,
                    icon: const Icon(Icons.person_add_alt_1),
                    label: Text(l10n.addEmployeeButton),
                  ),
                  FilledButton.tonalIcon(
                    onPressed:
                        capabilities.canManagePayroll && !viewModel.isSaving
                        ? viewModel.draftMonthlyPayrollRun
                        : null,
                    icon: const Icon(Icons.event_repeat_outlined),
                    label: Text(l10n.draftMonthlyPayrollButton),
                  ),
                  FilledButton.tonalIcon(
                    onPressed:
                        capabilities.canManagePayroll && !viewModel.isSaving
                        ? () => _showCreatePayrollSheet(context)
                        : null,
                    icon: const Icon(Icons.payments_outlined),
                    label: Text(l10n.createPayrollRunButton),
                  ),
                ],
              ),
              if (viewModel.hasSaveError) ...[
                SizedBox(height: spacing.sm),
                PointyInlineMessage.error(
                  message: l10n.employeePayrollSaveError,
                  icon: Icons.warning_amber_outlined,
                ),
              ],
              SizedBox(height: spacing.md),
              TabBar(
                tabs: [
                  Tab(text: l10n.employeesTabLabel),
                  Tab(text: l10n.payrollRunsTabLabel),
                  Tab(text: l10n.employeeLoansTabLabel),
                ],
              ),
              SizedBox(height: spacing.sm),
              Expanded(
                child: TabBarView(
                  children: [
                    _EmployeeList(
                      viewModel: viewModel,
                      capabilities: capabilities,
                    ),
                    _PayrollRunList(
                      viewModel: viewModel,
                      capabilities: capabilities,
                    ),
                    _EmployeeLoanList(
                      viewModel: viewModel,
                      capabilities: capabilities,
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

  Future<void> _showCreateEmployeeSheet(BuildContext context) {
    return showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.standard,
      maxHeightFactor: 0.94,
      builder: (sheetContext) => _CreateEmployeeForm(
        viewModel: viewModel,
        userRepository: userRepository,
        onCreated: () => Navigator.of(sheetContext).pop(),
      ),
    );
  }

  Future<void> _showCreatePayrollSheet(BuildContext context) {
    return showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.standard,
      maxHeightFactor: 0.94,
      builder: (sheetContext) => _CreatePayrollRunForm(
        viewModel: viewModel,
        onCreated: () => Navigator.of(sheetContext).pop(),
      ),
    );
  }
}

class _EmployeeList extends StatelessWidget {
  const _EmployeeList({required this.viewModel, required this.capabilities});

  final EmployeePayrollViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDataList<Employee>(
      items: viewModel.employees,
      onLoadMore: viewModel.loadMoreEmployees,
      hasMore: viewModel.hasMoreEmployees,
      isLoadingInitial: viewModel.isLoadingEmployees,
      isLoadingMore: viewModel.isLoadingMoreEmployees,
      hasError: viewModel.hasEmployeeError,
      errorBuilder: (context) => PointyErrorState(
        title: l10n.employeesLoadError,
        icon: Icons.badge_outlined,
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
              label: _employeeStatusLabel(l10n, employee.status),
              icon: Icons.circle_outlined,
            ),
            if (employee.hasSystemAccess)
              PointyStatusPill(
                label: l10n.employeeSystemAccessLabel(employee.userUsername),
                icon: Icons.verified_user_outlined,
              ),
            if (plan != null)
              PointyStatusPill(
                label: _compensationPlanLabel(l10n, plan),
                icon: Icons.payments_outlined,
              ),
          ],
          actions: [
            IconButton(
              tooltip: l10n.addCompensationPlanTooltip,
              onPressed: capabilities.canManageEmployees && !viewModel.isSaving
                  ? () => _showCompensationSheet(context, employee)
                  : null,
              icon: const Icon(Icons.price_change_outlined),
            ),
          ],
        );
      },
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

  Future<void> _showCompensationSheet(BuildContext context, Employee employee) {
    return showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.standard,
      maxHeightFactor: 0.94,
      builder: (sheetContext) => _CompensationPlanForm(
        viewModel: viewModel,
        employee: employee,
        onCreated: () => Navigator.of(sheetContext).pop(),
      ),
    );
  }
}

class _PayrollRunList extends StatelessWidget {
  const _PayrollRunList({required this.viewModel, required this.capabilities});

  final EmployeePayrollViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDataList<PayrollRun>(
      items: viewModel.payrollRuns,
      onLoadMore: viewModel.loadMorePayrollRuns,
      hasMore: viewModel.hasMorePayrollRuns,
      isLoadingInitial: viewModel.isLoadingPayrollRuns,
      isLoadingMore: viewModel.isLoadingMorePayrollRuns,
      hasError: viewModel.hasPayrollError,
      errorBuilder: (context) => PointyErrorState(
        title: l10n.payrollRunsLoadError,
        icon: Icons.payments_outlined,
      ),
      emptyBuilder: (context) => PointyEmptyState(
        icon: Icons.payments_outlined,
        title: l10n.emptyPayrollRuns,
      ),
      padding: EdgeInsets.zero,
      framed: false,
      itemBuilder: (context, run) {
        return PointyDataRow(
          leading: const CircleAvatar(child: Icon(Icons.payments_outlined)),
          title: run.runNumber,
          subtitle: _payrollSubtitle(l10n, run),
          onTap: () => _showPayrollRunDetails(context, run),
          trailing: Text(
            formatMoney(run.netTotal),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          badges: [
            PointyStatusPill(
              label: _payrollStatusLabel(l10n, run.status),
              icon: Icons.circle_outlined,
            ),
            PointyStatusPill(
              label: l10n.payrollLineCount(run.lineCount),
              icon: Icons.groups_outlined,
            ),
          ],
          actions: [
            IconButton(
              tooltip: l10n.payrollRunDetailsTooltip,
              onPressed: () => _showPayrollRunDetails(context, run),
              icon: const Icon(Icons.visibility_outlined),
            ),
            IconButton(
              tooltip: l10n.approvePayrollRunTooltip,
              onPressed:
                  capabilities.canManagePayroll &&
                      run.status.canApprove &&
                      !viewModel.isSaving
                  ? () => viewModel.approvePayrollRun(run)
                  : null,
              icon: const Icon(Icons.verified_outlined),
            ),
            IconButton(
              tooltip: l10n.markPayrollRunPaidTooltip,
              onPressed:
                  capabilities.canManagePayroll &&
                      run.status.canPay &&
                      !viewModel.isSaving
                  ? () => viewModel.markPayrollRunPaid(run)
                  : null,
              icon: const Icon(Icons.price_check_outlined),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showPayrollRunDetails(BuildContext context, PayrollRun run) {
    return showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.expanded,
      maxHeightFactor: 0.94,
      builder: (sheetContext) => _PayrollRunDetailSheet(
        viewModel: viewModel,
        capabilities: capabilities,
        initialRun: run,
      ),
    );
  }

  String _payrollSubtitle(AppLocalizations l10n, PayrollRun run) {
    return _payrollPeriodLabel(l10n, run);
  }
}

class _EmployeeLoanList extends StatelessWidget {
  const _EmployeeLoanList({
    required this.viewModel,
    required this.capabilities,
  });

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
      ),
      emptyBuilder: (context) => PointyEmptyState(
        icon: Icons.account_balance_wallet_outlined,
        title: l10n.emptyEmployeeLoans,
      ),
      padding: EdgeInsets.zero,
      framed: false,
      itemBuilder: (context, loan) {
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
              label: _loanStatusLabel(l10n, loan.status),
              icon: _loanStatusIcon(loan.status),
            ),
            PointyStatusPill(
              label: l10n.employeeLoanMonthlyDeductionDetail(
                formatMoney(loan.monthlyDeduction),
              ),
              icon: Icons.event_repeat_outlined,
            ),
          ],
          actions: [
            IconButton(
              tooltip: l10n.approveEmployeeLoanTooltip,
              onPressed:
                  capabilities.canManageEmployeeLoans &&
                      loan.status.canReview &&
                      !viewModel.isSaving
                  ? () => viewModel.approveLoan(loan)
                  : null,
              icon: const Icon(Icons.verified_outlined),
            ),
            IconButton(
              tooltip: l10n.rejectEmployeeLoanTooltip,
              onPressed:
                  capabilities.canManageEmployeeLoans &&
                      loan.status.canReview &&
                      !viewModel.isSaving
                  ? () => viewModel.rejectLoan(loan)
                  : null,
              icon: const Icon(Icons.cancel_outlined),
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

class _PayrollRunDetailSheet extends StatefulWidget {
  const _PayrollRunDetailSheet({
    required this.viewModel,
    required this.capabilities,
    required this.initialRun,
  });

  final EmployeePayrollViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final PayrollRun initialRun;

  @override
  State<_PayrollRunDetailSheet> createState() => _PayrollRunDetailSheetState();
}

class _PayrollRunDetailSheetState extends State<_PayrollRunDetailSheet> {
  late Future<PayrollRun?> _future;
  PayrollRun? _run;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<PayrollRun?> _load() async {
    final run = await widget.viewModel.loadPayrollRunDetail(widget.initialRun);
    if (mounted && run != null) {
      setState(() {
        _run = run;
      });
    }
    return run;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final activeRun = _run ?? widget.initialRun;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: FutureBuilder<PayrollRun?>(
        future: _future,
        builder: (context, snapshot) {
          final loadedRun = _run ?? snapshot.data;
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                ListenableBuilder(
                  listenable: widget.viewModel,
                  builder: (context, _) {
                    return PointySectionHeader(
                      title: l10n.payrollRunDetailsTitle(activeRun.runNumber),
                      subtitle: _payrollPeriodLabel(l10n, activeRun),
                      leading: const Icon(Icons.receipt_long_outlined),
                      trailing: PointyStatusPill(
                        label: _payrollStatusLabel(l10n, activeRun.status),
                        icon: Icons.circle_outlined,
                      ),
                      actions: [
                        FilledButton.icon(
                          onPressed:
                              widget.capabilities.canManagePayroll &&
                                  activeRun.status.canApprove &&
                                  !widget.viewModel.isSaving
                              ? _approveRun
                              : null,
                          icon: const Icon(Icons.verified_outlined),
                          label: Text(l10n.approvePayrollRunTooltip),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              widget.capabilities.canManagePayroll &&
                                  activeRun.status.canPay &&
                                  !widget.viewModel.isSaving
                              ? _markRunPaid
                              : null,
                          icon: const Icon(Icons.price_check_outlined),
                          label: Text(l10n.markPayrollRunPaidTooltip),
                        ),
                      ],
                    );
                  },
                ),
                SizedBox(height: spacing.sm),
                if (snapshot.connectionState == ConnectionState.waiting &&
                    loadedRun == null)
                  const PointyLoadingArea(minHeight: 260)
                else if (loadedRun == null)
                  PointyErrorState(
                    title: l10n.payrollRunDetailsLoadError,
                    icon: Icons.warning_amber_outlined,
                  )
                else
                  _PayrollRunDetailContent(
                    run: loadedRun,
                    viewModel: widget.viewModel,
                    capabilities: widget.capabilities,
                    onRunChanged: (run) {
                      setState(() {
                        _run = run;
                      });
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _approveRun() async {
    final run = _run ?? widget.initialRun;
    final saved = await widget.viewModel.approvePayrollRun(run);
    if (saved && mounted) {
      setState(() {
        _future = _load();
      });
    }
  }

  Future<void> _markRunPaid() async {
    final run = _run ?? widget.initialRun;
    final saved = await widget.viewModel.markPayrollRunPaid(run);
    if (saved && mounted) {
      setState(() {
        _future = _load();
      });
    }
  }
}

class _PayrollRunDetailContent extends StatelessWidget {
  const _PayrollRunDetailContent({
    required this.run,
    required this.viewModel,
    required this.capabilities,
    required this.onRunChanged,
  });

  final PayrollRun run;
  final EmployeePayrollViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final ValueChanged<PayrollRun> onRunChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final canEditPayrollLines =
        capabilities.canManagePayroll &&
        run.status == PayrollStatus.draft &&
        run.lines.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PointyMetricGrid(
          maxColumns: 4,
          minTileWidth: 180,
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
            ),
            PointyMetricGridItem(
              label: l10n.payrollRunDeductionsTotalLabel,
              value: formatMoney(run.deductionsTotal),
              icon: Icons.remove_circle_outline,
            ),
            PointyMetricGridItem(
              label: l10n.payrollRunNetTotalLabel,
              value: formatMoney(run.netTotal),
              icon: Icons.payments_outlined,
            ),
          ],
        ),
        SizedBox(height: spacing.md),
        PointyDetailSection(
          title: l10n.payrollRunSummarySection,
          icon: Icons.summarize_outlined,
          child: Column(
            children: [
              PointyDetailRow(
                label: l10n.payrollRunPeriodLabel,
                value: _payrollPeriodLabel(l10n, run),
              ),
              PointyDetailRow(
                label: l10n.payrollRunEmployeesSection,
                value: l10n.payrollLineCount(run.lineCount),
              ),
              PointyDetailRow(
                label: l10n.payrollRunPaymentDateLabel,
                value: run.paymentDate == null
                    ? l10n.missingDateLabel
                    : formatDate(run.paymentDate!),
              ),
              PointyDetailRow(
                label: l10n.payrollRunCreatedAtLabel,
                value: run.createdAt == null
                    ? l10n.missingDateLabel
                    : formatDateTime(run.createdAt!),
              ),
              if (run.approvedAt != null)
                PointyDetailRow(
                  label: l10n.payrollRunApprovedByLabel,
                  value: _actorWithDate(
                    l10n,
                    run.approvedByUsername,
                    run.approvedAt!,
                  ),
                ),
              if (run.paidAt != null)
                PointyDetailRow(
                  label: l10n.payrollRunPaidByLabel,
                  value: _actorWithDate(l10n, run.paidByUsername, run.paidAt!),
                ),
              PointyDetailRow(
                label: l10n.payrollRunNotesLabel,
                value: run.notes.trim().isEmpty
                    ? l10n.payrollRunNoNotes
                    : run.notes.trim(),
              ),
            ],
          ),
        ),
        SizedBox(height: spacing.md),
        PointyDetailSection(
          title: l10n.payrollRunEmployeesSection,
          icon: Icons.groups_outlined,
          trailing: canEditPayrollLines
              ? IconButton.filledTonal(
                  onPressed: viewModel.isSaving
                      ? null
                      : () => _showBulkAdjustmentSheet(context),
                  icon: const Icon(Icons.playlist_add_check_outlined),
                  tooltip: l10n.payrollBulkAdjustmentButton,
                )
              : null,
          child: run.lines.isEmpty
              ? PointyEmptyState(
                  icon: Icons.groups_outlined,
                  title: l10n.payrollRunNoEmployees,
                )
              : Column(
                  children: [
                    for (final line in run.lines) ...[
                      _PayrollLineCard(
                        run: run,
                        line: line,
                        viewModel: viewModel,
                        canEdit:
                            capabilities.canManagePayroll &&
                            run.status == PayrollStatus.draft,
                        onRunChanged: onRunChanged,
                      ),
                      SizedBox(height: spacing.sm),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _showBulkAdjustmentSheet(BuildContext context) async {
    final updatedRun = await showModalBottomSheet<PayrollRun>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) =>
          _PayrollBulkAdjustmentSheet(run: run, viewModel: viewModel),
    );
    if (updatedRun != null) {
      onRunChanged(updatedRun);
    }
  }

  String _actorWithDate(AppLocalizations l10n, String actor, DateTime date) {
    final formattedDate = formatDateTime(date);
    if (actor.trim().isEmpty) {
      return formattedDate;
    }
    return l10n.payrollRunActorWithDate(actor.trim(), formattedDate);
  }
}

class _PayrollLineCard extends StatelessWidget {
  const _PayrollLineCard({
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

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: spacing.compactPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                CircleAvatar(child: Text(_employeeInitial(l10n, line))),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _employeeLineTitle(l10n, line),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: spacing.xs),
                      Text(
                        _employeeLineSubtitle(l10n, line),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                SizedBox(width: spacing.sm),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatMoney(line.netAmount),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (canEdit) ...[
                      SizedBox(width: spacing.xs),
                      IconButton(
                        onPressed: viewModel.isSaving
                            ? null
                            : () => _showAdjustmentSheet(context),
                        icon: const Icon(Icons.tune_outlined),
                        tooltip: l10n.editPayrollLineAdjustmentsTooltip,
                      ),
                    ],
                  ],
                ),
              ],
            ),
            SizedBox(height: spacing.sm),
            Wrap(
              spacing: spacing.sm,
              runSpacing: spacing.sm,
              children: [
                _PayrollAmountChip(
                  label: l10n.payrollLineUnitsLabel,
                  value: line.units.toStringAsFixed(2),
                ),
                _PayrollAmountChip(
                  label: l10n.payrollLineRateLabel,
                  value: formatMoney(line.rate),
                ),
                _PayrollAmountChip(
                  label: l10n.payrollLineGrossLabel,
                  value: formatMoney(line.grossAmount),
                ),
                if (line.absenceDays > 0)
                  _PayrollAmountChip(
                    label: l10n.payrollLineAbsenceDaysLabel,
                    value: line.absenceDays.toStringAsFixed(2),
                  ),
                if (line.absenceDeductionAmount > 0)
                  _PayrollAmountChip(
                    label: l10n.payrollLineAbsenceDeductionLabel,
                    value: formatMoney(line.absenceDeductionAmount),
                  ),
                if (line.raiseAmount > 0)
                  _PayrollAmountChip(
                    label: l10n.payrollLineRaiseLabel,
                    value: formatMoney(line.raiseAmount),
                  ),
                if (line.manualAdditionAmount > 0)
                  _PayrollAmountChip(
                    label: l10n.manualAdditionAmountField,
                    value: formatMoney(line.manualAdditionAmount),
                  ),
                if (line.manualDeductionAmount > 0)
                  _PayrollAmountChip(
                    label: l10n.manualDeductionAmountField,
                    value: formatMoney(line.manualDeductionAmount),
                  ),
                _PayrollAmountChip(
                  label: l10n.payrollLineAdditionsLabel,
                  value: formatMoney(line.additionsAmount),
                ),
                _PayrollAmountChip(
                  label: l10n.payrollLineDeductionsLabel,
                  value: formatMoney(line.deductionsAmount),
                ),
              ],
            ),
            if (line.description.trim().isNotEmpty ||
                line.notes.trim().isNotEmpty ||
                line.adjustments.isNotEmpty) ...[
              Divider(height: spacing.lg),
              if (line.description.trim().isNotEmpty)
                PointyDetailRow(
                  label: l10n.payrollLineDescriptionLabel,
                  value: line.description.trim(),
                ),
              if (line.notes.trim().isNotEmpty)
                PointyDetailRow(
                  label: l10n.payrollLineNotesLabel,
                  value: line.notes.trim(),
                ),
              if (line.adjustments.isNotEmpty) ...[
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    l10n.payrollLineAdjustmentsLabel,
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                SizedBox(height: spacing.xs),
                for (final adjustment in line.adjustments)
                  _PayrollAdjustmentRow(adjustment: adjustment),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showAdjustmentSheet(BuildContext context) async {
    final updatedRun = await showModalBottomSheet<PayrollRun>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => _PayrollLineAdjustmentSheet(
        run: run,
        line: line,
        viewModel: viewModel,
      ),
    );
    if (updatedRun != null) {
      onRunChanged(updatedRun);
    }
  }

  String _employeeInitial(AppLocalizations l10n, PayrollLine line) {
    final title = _employeeLineTitle(l10n, line).trim();
    return title.isEmpty ? '#' : title.characters.first;
  }

  String _employeeLineTitle(AppLocalizations l10n, PayrollLine line) {
    return line.employeeName.trim().isEmpty
        ? l10n.payrollEmployeeFallbackLabel(line.employeeId)
        : line.employeeName.trim();
  }

  String _employeeLineSubtitle(AppLocalizations l10n, PayrollLine line) {
    final parts = [
      if (line.employeeNumber.trim().isNotEmpty) line.employeeNumber.trim(),
      _payrollLinePayLabel(l10n, line),
    ];
    return parts.join(' - ');
  }
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
    final amount = _decimalValue(_amountController.text);
    final selectedCount = _selectedLineIds.length;
    final totalImpact = _roundMoney(amount * selectedCount);
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
                        _employeeLineTitle(l10n, line),
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
                          color: theme.colorScheme.error,
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
              child: Column(
                children: [
                  PointyDetailRow(
                    label: l10n.payrollBulkSelectedEmployeesLabel,
                    value: l10n.payrollLineCount(selectedCount),
                  ),
                  PointyDetailRow(
                    label: l10n.payrollBulkAmountPerEmployeeLabel,
                    value: formatMoney(amount),
                  ),
                  PointyDetailRow(
                    label: _type == PayrollBulkAdjustmentType.deduction
                        ? l10n.payrollBulkTotalDeductionLabel
                        : l10n.payrollBulkTotalAdditionLabel,
                    value: formatMoney(totalImpact),
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
              Text(
                l10n.payrollBulkAdjustmentSaveError,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
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
    final amount = _decimalValue(_amountController.text);
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
        amount: _decimalPayload(_amountController.text),
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

  String _employeeLineTitle(AppLocalizations l10n, PayrollLine line) {
    return line.employeeName.trim().isEmpty
        ? l10n.payrollEmployeeFallbackLabel(line.employeeId)
        : line.employeeName.trim();
  }

  String _employeeLineSubtitle(AppLocalizations l10n, PayrollLine line) {
    final parts = [
      if (line.employeeNumber.trim().isNotEmpty) line.employeeNumber.trim(),
      _payrollLinePayLabel(l10n, line),
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
  late final TextEditingController _raiseAmountController;
  late final TextEditingController _manualAdditionController;
  late final TextEditingController _manualDeductionController;
  late final TextEditingController _notesController;

  @override
  void initState() {
    super.initState();
    _absenceDaysController = TextEditingController(
      text: _decimalInput(widget.line.absenceDays),
    );
    _raiseAmountController = TextEditingController(
      text: _decimalInput(widget.line.raiseAmount),
    );
    _manualAdditionController = TextEditingController(
      text: _decimalInput(widget.line.manualAdditionAmount),
    );
    _manualDeductionController = TextEditingController(
      text: _decimalInput(widget.line.manualDeductionAmount),
    );
    _notesController = TextEditingController(text: widget.line.notes);
    for (final controller in _amountControllers) {
      controller.addListener(_refreshPreview);
    }
  }

  List<TextEditingController> get _amountControllers => [
    _absenceDaysController,
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
    final periodDays = _payrollPeriodDays(widget.run);
    final absenceDays = _decimalValue(_absenceDaysController.text);
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
                _employeeLineTitle(l10n, widget.line),
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
              child: Column(
                children: [
                  PointyDetailRow(
                    label: l10n.payrollLineGrossLabel,
                    value: formatMoney(widget.line.grossAmount),
                  ),
                  PointyDetailRow(
                    label: l10n.payrollLineAbsenceDeductionLabel,
                    value: formatMoney(absenceDeduction),
                  ),
                  PointyDetailRow(
                    label: l10n.payrollLineAdditionsLabel,
                    value: formatMoney(projectedAdditions),
                  ),
                  PointyDetailRow(
                    label: l10n.payrollLineDeductionsLabel,
                    value: formatMoney(projectedDeductions),
                  ),
                  PointyDetailRow(
                    label: l10n.payrollLineProjectedNetLabel,
                    value: formatMoney(projectedNet),
                  ),
                ],
              ),
            ),
            if (hasNetError) ...[
              SizedBox(height: spacing.sm),
              Text(
                l10n.negativeNetPayrollLineError,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
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
              Text(
                l10n.payrollLineAdjustmentSaveError,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
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
    final periodDays = _payrollPeriodDays(widget.run);
    if (periodDays <= 0) {
      return 0;
    }
    return widget.line.grossAmount / periodDays;
  }

  double get _absenceDeduction {
    return _roundMoney(
      _decimalValue(_absenceDaysController.text) * _absenceDayRate,
    );
  }

  double get _projectedAdditions {
    return _roundMoney(
      _existingAdjustmentAdditions +
          _decimalValue(_raiseAmountController.text) +
          _decimalValue(_manualAdditionController.text),
    );
  }

  double get _projectedDeductions {
    return _roundMoney(
      _existingAdjustmentDeductions +
          _absenceDeduction +
          _decimalValue(_manualDeductionController.text),
    );
  }

  double get _projectedNet {
    return _roundMoney(
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
        .where((adjustment) => adjustment.direction == 'deduction')
        .fold<double>(0, (total, adjustment) => total + adjustment.amount);
  }

  String _employeeLineTitle(AppLocalizations l10n, PayrollLine line) {
    return line.employeeName.trim().isEmpty
        ? l10n.payrollEmployeeFallbackLabel(line.employeeId)
        : line.employeeName.trim();
  }

  Future<void> _save() async {
    final updatedRun = await widget.viewModel.updatePayrollLineAdjustments(
      widget.run,
      widget.line,
      PayrollLineAdjustmentDraft(
        absenceDays: _decimalPayload(_absenceDaysController.text),
        raiseAmount: _decimalPayload(_raiseAmountController.text),
        manualAdditionAmount: _decimalPayload(_manualAdditionController.text),
        manualDeductionAmount: _decimalPayload(_manualDeductionController.text),
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

class _PayrollAmountChip extends StatelessWidget {
  const _PayrollAmountChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Chip(
      label: Text(l10n.payrollLineAmountDetail(label, value)),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _PayrollAdjustmentRow extends StatelessWidget {
  const _PayrollAdjustmentRow({required this.adjustment});

  final PayrollAdjustment adjustment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final direction = _payrollAdjustmentDirectionLabel(
      l10n,
      adjustment.direction,
    );
    final type = _payrollAdjustmentTypeLabel(l10n, adjustment.adjustmentType);
    final notes = adjustment.notes.trim();

    final amount = formatMoney(adjustment.amount);
    return PointyDetailRow(
      label: l10n.payrollAdjustmentDetailLabel(direction, type),
      value: notes.isEmpty
          ? amount
          : l10n.payrollAdjustmentAmountWithNotes(amount, notes),
    );
  }
}

class _CreateEmployeeForm extends StatefulWidget {
  const _CreateEmployeeForm({
    required this.viewModel,
    required this.userRepository,
    required this.onCreated,
  });

  final EmployeePayrollViewModel viewModel;
  final UserRepository userRepository;
  final VoidCallback onCreated;

  @override
  State<_CreateEmployeeForm> createState() => _CreateEmployeeFormState();
}

class _CreateEmployeeFormState extends State<_CreateEmployeeForm> {
  final _nameController = TextEditingController();
  final _jobController = TextEditingController();
  final _departmentController = TextEditingController();
  final _phoneController = TextEditingController();
  DateTime _hireDate = DateTime.now();
  EmploymentType _employmentType = EmploymentType.fullTime;
  AsyncSelectionOption<int>? _selectedUser;

  @override
  void dispose() {
    _nameController.dispose();
    _jobController.dispose();
    _departmentController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _SheetFrame(
      title: l10n.addEmployeeButton,
      children: [
        TextField(
          controller: _nameController,
          decoration: InputDecoration(labelText: l10n.employeeNameField),
          textInputAction: TextInputAction.next,
        ),
        TextField(
          controller: _jobController,
          decoration: InputDecoration(labelText: l10n.employeeJobTitleField),
          textInputAction: TextInputAction.next,
        ),
        TextField(
          controller: _departmentController,
          decoration: InputDecoration(labelText: l10n.employeeDepartmentField),
          textInputAction: TextInputAction.next,
        ),
        TextField(
          controller: _phoneController,
          decoration: InputDecoration(labelText: l10n.employeePhoneField),
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
        ),
        _DatePickerField(
          label: l10n.employeeHireDateField,
          value: _hireDate,
          onChanged: (value) => setState(() => _hireDate = value),
        ),
        AsyncSelectionField<int>(
          fieldKey: const ValueKey('employee_user_field'),
          strings: AsyncSelectionFieldStrings<int>(
            label: l10n.employeeUserField,
            emptyText: l10n.employeeUserEmpty,
            helperText: l10n.employeeUserHelper,
            clearTooltip: l10n.employeeUserClearTooltip,
            openPickerTooltip: l10n.employeeUserOpenPickerTooltip,
            fallbackLabelForId: (id) => l10n.userFallbackLabel(id),
          ),
          selected: [?_selectedUser],
          onPick: _pickUser,
          onClear: _selectedUser == null
              ? null
              : () => setState(() => _selectedUser = null),
          validator: (_) => null,
        ),
        DropdownButtonFormField<EmploymentType>(
          initialValue: _employmentType,
          decoration: InputDecoration(labelText: l10n.employeeTypeField),
          items: [
            for (final type in EmploymentType.values)
              DropdownMenuItem(
                value: type,
                child: Text(_employmentTypeLabel(l10n, type)),
              ),
          ],
          onChanged: (value) {
            if (value != null) {
              setState(() => _employmentType = value);
            }
          },
        ),
        FilledButton.icon(
          onPressed: widget.viewModel.isSaving ? null : _submit,
          icon: const Icon(Icons.save_outlined),
          label: Text(l10n.saveButton),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      return;
    }
    final saved = await widget.viewModel.createEmployee(
      EmployeeDraft(
        fullName: name,
        jobTitle: _jobController.text.trim(),
        department: _departmentController.text.trim(),
        phone: _phoneController.text.trim(),
        hireDate: _dateIso(_hireDate),
        employmentType: _employmentType,
        userId: _selectedUser?.id,
      ),
    );
    if (saved && mounted) {
      widget.onCreated();
    }
  }

  Future<void> _pickUser() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: AsyncSelectionPickerStrings<int>(
        title: l10n.employeeUserPickerTitle,
        searchHint: l10n.employeeUserPickerSearchHint,
        emptyText: l10n.employeeUserPickerEmpty,
        clearText: l10n.employeeUserPickerClear,
        clearSearchTooltip: l10n.clearSearchTooltip,
        loadErrorText: l10n.employeeUserPickerLoadError,
        confirmText: l10n.confirmButton,
        fallbackLabelForId: (id) => l10n.userFallbackLabel(id),
      ),
      selected: [?_selectedUser],
      loadPage: _loadUserSelectionPage,
      optionKeyForId: (id) => ValueKey('employee_user_option_$id'),
      heightFactor: 0.74,
      singleSelection: true,
    );
    if (picked == null) {
      return;
    }
    final selected = picked.isEmpty ? null : picked.last;
    setState(() {
      _selectedUser = selected;
      if (selected != null && _nameController.text.trim().isEmpty) {
        _nameController.text = selected.label;
      }
    });
  }

  Future<AsyncSelectionPage<int>> _loadUserSelectionPage(
    String search,
    int page,
  ) async {
    final result = await widget.userRepository.loadUsers(
      search: search,
      page: page,
    );
    switch (result) {
      case Ok<PosUserPage>(value: final userPage):
        return AsyncSelectionPage<int>(
          options: userPage.users.map(_userOption).toList(growable: false),
          hasMore: userPage.hasMore,
        );
      case Error<PosUserPage>():
        throw Exception('Failed to load users');
    }
  }
}

class _CompensationPlanForm extends StatefulWidget {
  const _CompensationPlanForm({
    required this.viewModel,
    required this.employee,
    required this.onCreated,
  });

  final EmployeePayrollViewModel viewModel;
  final Employee employee;
  final VoidCallback onCreated;

  @override
  State<_CompensationPlanForm> createState() => _CompensationPlanFormState();
}

class _CompensationPlanFormState extends State<_CompensationPlanForm> {
  final _baseSalaryController = TextEditingController();
  final _commissionController = TextEditingController(text: '0.00');
  final _expectedUnitsController = TextEditingController(text: '1.00');
  final _notesController = TextEditingController();
  SalaryType _salaryType = SalaryType.monthlyFixed;
  bool _submitted = false;

  @override
  void dispose() {
    _baseSalaryController.dispose();
    _commissionController.dispose();
    _expectedUnitsController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _SheetFrame(
      title: l10n.addCompensationPlanTitle(widget.employee.fullName),
      children: [
        DropdownButtonFormField<SalaryType>(
          initialValue: _salaryType,
          decoration: InputDecoration(labelText: l10n.salaryTypeField),
          items: SalaryType.values
              .map(
                (type) => DropdownMenuItem(
                  value: type,
                  child: Text(_salaryTypeLabel(l10n, type)),
                ),
              )
              .toList(),
          onChanged: widget.viewModel.isSaving
              ? null
              : (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    final previousDefault = _defaultUnitsForType(_salaryType);
                    _salaryType = value;
                    if (_expectedUnitsController.text.trim().isEmpty ||
                        _expectedUnitsController.text.trim() ==
                            previousDefault) {
                      _expectedUnitsController.text = _defaultUnitsForType(
                        value,
                      );
                    }
                  });
                },
        ),
        PointyInlineMessage(
          message: _salaryTypeHelper(l10n, _salaryType),
          icon: Icons.payments_outlined,
          compact: true,
        ),
        if (_requiresBaseSalary)
          TextField(
            controller: _baseSalaryController,
            decoration: InputDecoration(
              labelText: _amountFieldLabel(l10n, _salaryType),
              helperText: _amountFieldHelper(l10n, _salaryType),
              errorText: _submitted && !_hasPositiveValue(_baseSalaryController)
                  ? l10n.baseSalaryRequiredError
                  : null,
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
          ),
        if (_requiresExpectedUnits)
          TextField(
            controller: _expectedUnitsController,
            decoration: InputDecoration(
              labelText: l10n.expectedUnitsPerPeriodField,
              helperText: _expectedUnitsHelper(l10n, _salaryType),
              errorText:
                  _submitted && !_hasPositiveValue(_expectedUnitsController)
                  ? l10n.expectedUnitsRequiredError
                  : null,
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
          ),
        if (_requiresCommission)
          TextField(
            controller: _commissionController,
            decoration: InputDecoration(
              labelText: l10n.salesCommissionPercentField,
              helperText: l10n.salesCommissionPercentHelper,
              errorText: _submitted && !_hasPositiveValue(_commissionController)
                  ? l10n.commissionRequiredError
                  : null,
              suffixText: '%',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
          ),
        if (_requiresCommission && !widget.employee.hasSystemAccess)
          PointyInlineMessage(
            message: l10n.salesCommissionNeedsLinkedUserWarning,
            icon: Icons.link_off_outlined,
            compact: true,
          ),
        if (_showsNotes)
          TextField(
            controller: _notesController,
            decoration: InputDecoration(
              labelText: l10n.compensationNotesField,
              helperText: l10n.compensationNotesHelper,
            ),
            minLines: 2,
            maxLines: 4,
            textInputAction: TextInputAction.newline,
          ),
        PointyInlineMessage(
          message: l10n.compensationPlanActivationNote,
          icon: Icons.info_outline,
          compact: true,
        ),
        FilledButton.icon(
          onPressed: widget.viewModel.isSaving ? null : _submit,
          icon: const Icon(Icons.save_outlined),
          label: Text(l10n.saveButton),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    setState(() {
      _submitted = true;
    });
    if (_hasInputErrors) {
      return;
    }
    final saved = await widget.viewModel.createCompensationPlan(
      CompensationPlanDraft(
        employeeId: widget.employee.id,
        salaryType: _salaryType,
        amount: _requiresBaseSalary
            ? _baseSalaryController.text.trim()
            : '0.00',
        commissionPercent: _requiresCommission
            ? _commissionController.text.trim()
            : '0.00',
        expectedUnitsPerPeriod: _requiresExpectedUnits
            ? _expectedUnitsController.text.trim()
            : '1.00',
        notes: _showsNotes ? _notesController.text.trim() : '',
      ),
    );
    if (saved && mounted) {
      widget.onCreated();
    }
  }

  bool get _requiresBaseSalary {
    return _salaryType != SalaryType.salesCommissionOnly;
  }

  bool get _requiresCommission {
    return _salaryType == SalaryType.salesCommissionOnly ||
        _salaryType == SalaryType.monthlyFixedPlusSalesCommission;
  }

  bool get _requiresExpectedUnits {
    return _salaryType == SalaryType.weeklyFixed ||
        _salaryType == SalaryType.dailyRate ||
        _salaryType == SalaryType.hourlyRate ||
        _salaryType == SalaryType.perShift;
  }

  bool get _showsNotes {
    return _salaryType == SalaryType.contractFixed ||
        _salaryType == SalaryType.customFixed;
  }

  bool get _hasInputErrors {
    return (_requiresBaseSalary && !_hasPositiveValue(_baseSalaryController)) ||
        (_requiresExpectedUnits &&
            !_hasPositiveValue(_expectedUnitsController)) ||
        (_requiresCommission && !_hasPositiveValue(_commissionController));
  }

  bool _hasPositiveValue(TextEditingController controller) {
    final value = double.tryParse(controller.text.trim()) ?? 0;
    return value > 0;
  }
}

class _CreatePayrollRunForm extends StatefulWidget {
  const _CreatePayrollRunForm({
    required this.viewModel,
    required this.onCreated,
  });

  final EmployeePayrollViewModel viewModel;
  final VoidCallback onCreated;

  @override
  State<_CreatePayrollRunForm> createState() => _CreatePayrollRunFormState();
}

class _CreatePayrollRunFormState extends State<_CreatePayrollRunForm> {
  final _unitsController = TextEditingController(text: '1.00');
  late DateTime _periodStart;
  late DateTime _periodEnd;
  Employee? _employee;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _periodStart = DateTime(now.year, now.month);
    _periodEnd = now;
  }

  @override
  void dispose() {
    _unitsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final employeesWithPlans = widget.viewModel.employees
        .where((employee) => employee.activeCompensationPlan != null)
        .toList(growable: false);
    if (_employee == null && employeesWithPlans.isNotEmpty) {
      _employee = employeesWithPlans.first;
    }

    return _SheetFrame(
      title: l10n.createPayrollRunButton,
      children: [
        if (employeesWithPlans.isEmpty)
          PointyInlineMessage.warning(
            message: l10n.noEmployeesWithPayPlan,
            icon: Icons.info_outline,
          )
        else
          DropdownButtonFormField<Employee>(
            initialValue: _employee,
            decoration: InputDecoration(labelText: l10n.payrollEmployeeField),
            items: [
              for (final employee in employeesWithPlans)
                DropdownMenuItem(
                  value: employee,
                  child: Text(employee.fullName),
                ),
            ],
            onChanged: (value) => setState(() => _employee = value),
          ),
        _DatePickerField(
          label: l10n.payrollPeriodStartField,
          value: _periodStart,
          onChanged: (value) {
            setState(() {
              _periodStart = value;
              if (_periodEnd.isBefore(value)) {
                _periodEnd = value;
              }
            });
          },
        ),
        _DatePickerField(
          label: l10n.payrollPeriodEndField,
          value: _periodEnd,
          firstDate: _periodStart,
          onChanged: (value) => setState(() => _periodEnd = value),
        ),
        TextField(
          controller: _unitsController,
          decoration: InputDecoration(labelText: l10n.payUnitsField),
          keyboardType: TextInputType.number,
          inputFormatters: [DecimalTextInputFormatter()],
        ),
        FilledButton.icon(
          onPressed: widget.viewModel.isSaving || _employee == null
              ? null
              : _submit,
          icon: const Icon(Icons.save_outlined),
          label: Text(l10n.saveButton),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final employee = _employee;
    final plan = employee?.activeCompensationPlan;
    if (employee == null || plan == null) {
      return;
    }
    final saved = await widget.viewModel.createPayrollRun(
      PayrollRunDraft(
        periodStart: _dateIso(_periodStart),
        periodEnd: _dateIso(_periodEnd),
        lines: [
          PayrollLineDraft(
            employeeId: employee.id,
            compensationPlanId: plan.id,
            units: _unitsController.text.trim(),
          ),
        ],
      ),
    );
    if (saved && mounted) {
      widget.onCreated();
    }
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
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
              title: title,
              leading: const Icon(Icons.badge_outlined),
            ),
            const SizedBox(height: 12),
            for (final child in children) ...[
              child,
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}

class _DatePickerField extends StatelessWidget {
  const _DatePickerField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.firstDate,
  });

  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onChanged;
  final DateTime? firstDate;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      key: ValueKey('$label-${_dateIso(value)}'),
      initialValue: formatDate(value),
      readOnly: true,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: const Icon(Icons.event_outlined),
      ),
      onTap: () async {
        final now = DateTime.now();
        final selected = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: firstDate ?? DateTime(now.year - 10),
          lastDate: DateTime(now.year + 5, 12, 31),
        );
        if (selected != null) {
          onChanged(selected);
        }
      },
    );
  }
}

AsyncSelectionOption<int> _userOption(PosUser user) {
  final subtitleParts = [
    user.username,
    if (user.email.trim().isNotEmpty) user.email.trim(),
  ].where((value) => value.trim().isNotEmpty).toList(growable: false);
  return AsyncSelectionOption<int>(
    id: user.id,
    label: user.label,
    subtitle: subtitleParts.join(' - '),
  );
}

String _dateIso(DateTime date) {
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

String _employeeStatusLabel(AppLocalizations l10n, EmployeeStatus status) {
  return switch (status) {
    EmployeeStatus.active => l10n.employeeStatusActive,
    EmployeeStatus.onLeave => l10n.employeeStatusOnLeave,
    EmployeeStatus.inactive => l10n.employeeStatusInactive,
    EmployeeStatus.terminated => l10n.employeeStatusTerminated,
  };
}

String _employmentTypeLabel(AppLocalizations l10n, EmploymentType type) {
  return switch (type) {
    EmploymentType.fullTime => l10n.employmentTypeFullTime,
    EmploymentType.partTime => l10n.employmentTypePartTime,
    EmploymentType.contractor => l10n.employmentTypeContractor,
    EmploymentType.seasonal => l10n.employmentTypeSeasonal,
    EmploymentType.intern => l10n.employmentTypeIntern,
    EmploymentType.other => l10n.employmentTypeOther,
  };
}

String _salaryTypeLabel(AppLocalizations l10n, SalaryType type) {
  return switch (type) {
    SalaryType.monthlyFixed => l10n.salaryTypeMonthlyFixed,
    SalaryType.weeklyFixed => l10n.salaryTypeWeeklyFixed,
    SalaryType.dailyRate => l10n.salaryTypeDailyRate,
    SalaryType.hourlyRate => l10n.salaryTypeHourlyRate,
    SalaryType.perShift => l10n.salaryTypePerShift,
    SalaryType.salesCommissionOnly => l10n.salaryTypeSalesCommissionOnly,
    SalaryType.monthlyFixedPlusSalesCommission =>
      l10n.salaryTypeMonthlyFixedPlusSalesCommission,
    SalaryType.contractFixed => l10n.salaryTypeContractFixed,
    SalaryType.customFixed => l10n.salaryTypeCustomFixed,
  };
}

String _salaryTypeHelper(AppLocalizations l10n, SalaryType type) {
  return switch (type) {
    SalaryType.monthlyFixed => l10n.salaryTypeMonthlyFixedHelper,
    SalaryType.weeklyFixed => l10n.salaryTypeWeeklyFixedHelper,
    SalaryType.dailyRate => l10n.salaryTypeDailyRateHelper,
    SalaryType.hourlyRate => l10n.salaryTypeHourlyRateHelper,
    SalaryType.perShift => l10n.salaryTypePerShiftHelper,
    SalaryType.salesCommissionOnly => l10n.salaryTypeSalesCommissionOnlyHelper,
    SalaryType.monthlyFixedPlusSalesCommission =>
      l10n.salaryTypeMonthlyFixedPlusSalesCommissionHelper,
    SalaryType.contractFixed => l10n.salaryTypeContractFixedHelper,
    SalaryType.customFixed => l10n.salaryTypeCustomFixedHelper,
  };
}

String _amountFieldLabel(AppLocalizations l10n, SalaryType type) {
  return switch (type) {
    SalaryType.monthlyFixed => l10n.monthlyBaseSalaryField,
    SalaryType.weeklyFixed => l10n.weeklyAmountField,
    SalaryType.dailyRate => l10n.dailyRateField,
    SalaryType.hourlyRate => l10n.hourlyRateField,
    SalaryType.perShift => l10n.shiftRateField,
    SalaryType.monthlyFixedPlusSalesCommission => l10n.monthlyBaseSalaryField,
    SalaryType.contractFixed => l10n.contractAmountField,
    SalaryType.customFixed => l10n.customAmountField,
    SalaryType.salesCommissionOnly => l10n.compensationAmountField,
  };
}

String _amountFieldHelper(AppLocalizations l10n, SalaryType type) {
  return switch (type) {
    SalaryType.monthlyFixed => l10n.monthlyBaseSalaryHelper,
    SalaryType.monthlyFixedPlusSalesCommission => l10n.monthlyBaseSalaryHelper,
    _ => _salaryTypeHelper(l10n, type),
  };
}

String _expectedUnitsHelper(AppLocalizations l10n, SalaryType type) {
  return switch (type) {
    SalaryType.weeklyFixed => l10n.expectedWeeksPerPeriodHelper,
    SalaryType.dailyRate => l10n.expectedDaysPerPeriodHelper,
    SalaryType.hourlyRate => l10n.expectedHoursPerPeriodHelper,
    SalaryType.perShift => l10n.expectedShiftsPerPeriodHelper,
    _ => '',
  };
}

String _defaultUnitsForType(SalaryType type) {
  return switch (type) {
    SalaryType.weeklyFixed => '4.00',
    SalaryType.dailyRate => '22.00',
    SalaryType.hourlyRate => '160.00',
    SalaryType.perShift => '22.00',
    _ => '1.00',
  };
}

String _payTypeLabel(AppLocalizations l10n, PayType type) {
  return switch (type) {
    PayType.monthlySalary => l10n.payTypeMonthlySalary,
    PayType.weeklySalary => l10n.payTypeWeeklySalary,
    PayType.dailyRate => l10n.payTypeDailyRate,
    PayType.hourly => l10n.payTypeHourly,
    PayType.perShift => l10n.payTypePerShift,
    PayType.commission => l10n.payTypeCommission,
    PayType.contract => l10n.payTypeContract,
    PayType.other => l10n.payTypeOther,
  };
}

String _payrollPeriodLabel(AppLocalizations l10n, PayrollRun run) {
  final start = run.periodStart == null
      ? l10n.missingDateLabel
      : formatDate(run.periodStart!);
  final end = run.periodEnd == null
      ? l10n.missingDateLabel
      : formatDate(run.periodEnd!);
  return l10n.payrollPeriodSubtitle(start, end);
}

int _payrollPeriodDays(PayrollRun run) {
  final start = run.periodStart;
  final end = run.periodEnd;
  if (start == null || end == null || end.isBefore(start)) {
    return 0;
  }
  return end.difference(start).inDays + 1;
}

String _decimalInput(double value) {
  return value.toStringAsFixed(2);
}

String _decimalPayload(String value) {
  return _decimalValue(value).toStringAsFixed(2);
}

double _decimalValue(String value) {
  return double.tryParse(value.trim().replaceAll(',', '.')) ?? 0;
}

double _roundMoney(double value) {
  return double.parse(value.toStringAsFixed(2));
}

String _payrollLinePayLabel(AppLocalizations l10n, PayrollLine line) {
  final salaryType = line.salaryType;
  if (salaryType != null) {
    return _salaryTypeLabel(l10n, salaryType);
  }
  final payType = line.payType;
  if (payType != null) {
    return _payTypeLabel(l10n, payType);
  }
  return l10n.payrollLineManualPayLabel;
}

String _compensationPlanLabel(AppLocalizations l10n, CompensationPlan plan) {
  final salaryType = plan.salaryType;
  if (salaryType != null) {
    return switch (salaryType) {
      SalaryType.monthlyFixed => l10n.employeeMonthlyFixedPlanLabel(
        formatMoney(plan.amount),
      ),
      SalaryType.weeklyFixed ||
      SalaryType.dailyRate ||
      SalaryType.hourlyRate ||
      SalaryType.perShift => l10n.employeeUnitBasedPlanLabel(
        _salaryTypeLabel(l10n, salaryType),
        formatMoney(plan.amount),
        plan.expectedUnitsPerPeriod.toStringAsFixed(2),
      ),
      SalaryType.salesCommissionOnly => l10n.employeeCommissionOnlyPlanLabel(
        plan.commissionPercent.toStringAsFixed(2),
      ),
      SalaryType.monthlyFixedPlusSalesCommission =>
        l10n.employeeMonthlyFixedPlusCommissionPlanLabel(
          formatMoney(plan.amount),
          plan.commissionPercent.toStringAsFixed(2),
        ),
      SalaryType.contractFixed ||
      SalaryType.customFixed => l10n.employeePayPlanLabel(
        _salaryTypeLabel(l10n, salaryType),
        formatMoney(plan.amount),
      ),
    };
  }
  final baseLabel = l10n.employeePayPlanLabel(
    _payTypeLabel(l10n, plan.payType),
    formatMoney(plan.amount),
  );
  if (plan.commissionPercent <= 0) {
    return baseLabel;
  }
  return l10n.employeePayPlanWithCommissionLabel(
    baseLabel,
    plan.commissionPercent.toStringAsFixed(2),
  );
}

String _payrollStatusLabel(AppLocalizations l10n, PayrollStatus status) {
  return switch (status) {
    PayrollStatus.draft => l10n.payrollStatusDraft,
    PayrollStatus.approved => l10n.payrollStatusApproved,
    PayrollStatus.paid => l10n.payrollStatusPaid,
    PayrollStatus.voided => l10n.payrollStatusVoid,
  };
}

String _loanStatusLabel(AppLocalizations l10n, EmployeeLoanStatus status) {
  return switch (status) {
    EmployeeLoanStatus.requested => l10n.employeeLoanStatusRequested,
    EmployeeLoanStatus.approved => l10n.employeeLoanStatusApproved,
    EmployeeLoanStatus.rejected => l10n.employeeLoanStatusRejected,
    EmployeeLoanStatus.cancelled => l10n.employeeLoanStatusCancelled,
    EmployeeLoanStatus.paid => l10n.employeeLoanStatusPaid,
  };
}

IconData _loanStatusIcon(EmployeeLoanStatus status) {
  return switch (status) {
    EmployeeLoanStatus.requested => Icons.hourglass_top_outlined,
    EmployeeLoanStatus.approved => Icons.verified_outlined,
    EmployeeLoanStatus.rejected => Icons.cancel_outlined,
    EmployeeLoanStatus.cancelled => Icons.block_outlined,
    EmployeeLoanStatus.paid => Icons.task_alt_outlined,
  };
}

String _payrollAdjustmentDirectionLabel(
  AppLocalizations l10n,
  String direction,
) {
  return switch (direction) {
    'addition' => l10n.payrollAdjustmentAddition,
    'deduction' => l10n.payrollAdjustmentDeduction,
    _ => l10n.payrollAdjustmentOther,
  };
}

String _payrollAdjustmentTypeLabel(AppLocalizations l10n, String type) {
  return switch (type) {
    'bonus' => l10n.payrollAdjustmentBonus,
    'commission' => l10n.payrollAdjustmentCommission,
    'overtime' => l10n.payrollAdjustmentOvertime,
    'reimbursement' => l10n.payrollAdjustmentReimbursement,
    'advance' => l10n.payrollAdjustmentAdvance,
    'loan' => l10n.payrollAdjustmentLoan,
    'absence' => l10n.payrollAdjustmentAbsence,
    'penalty' => l10n.payrollAdjustmentPenalty,
    _ => l10n.payrollAdjustmentOther,
  };
}
