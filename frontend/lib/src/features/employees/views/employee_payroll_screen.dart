import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/employee.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/employee_payroll_view_model.dart';

class EmployeePayrollScreen extends StatelessWidget {
  const EmployeePayrollScreen({
    super.key,
    required this.viewModel,
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
                viewModel.isLoadingEmployees || viewModel.isLoadingPayrollRuns,
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
    required this.capabilities,
  });

  final EmployeePayrollViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return DefaultTabController(
      length: 2,
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
                label: l10n.employeePayPlanLabel(
                  _payTypeLabel(l10n, plan.payType),
                  formatMoney(plan.amount),
                ),
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

  String _payrollSubtitle(AppLocalizations l10n, PayrollRun run) {
    final start = run.periodStart == null
        ? l10n.missingDateLabel
        : formatDate(run.periodStart!);
    final end = run.periodEnd == null
        ? l10n.missingDateLabel
        : formatDate(run.periodEnd!);
    return l10n.payrollPeriodSubtitle(start, end);
  }
}

class _CreateEmployeeForm extends StatefulWidget {
  const _CreateEmployeeForm({required this.viewModel, required this.onCreated});

  final EmployeePayrollViewModel viewModel;
  final VoidCallback onCreated;

  @override
  State<_CreateEmployeeForm> createState() => _CreateEmployeeFormState();
}

class _CreateEmployeeFormState extends State<_CreateEmployeeForm> {
  final _nameController = TextEditingController();
  final _jobController = TextEditingController();
  final _departmentController = TextEditingController();
  final _phoneController = TextEditingController();
  final _hireDateController = TextEditingController(text: _todayIso());
  EmploymentType _employmentType = EmploymentType.fullTime;

  @override
  void dispose() {
    _nameController.dispose();
    _jobController.dispose();
    _departmentController.dispose();
    _phoneController.dispose();
    _hireDateController.dispose();
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
        TextField(
          controller: _hireDateController,
          decoration: InputDecoration(labelText: l10n.employeeHireDateField),
          keyboardType: TextInputType.datetime,
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
        hireDate: _hireDateController.text.trim(),
        employmentType: _employmentType,
      ),
    );
    if (saved && mounted) {
      widget.onCreated();
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
  final _amountController = TextEditingController();
  final _unitsController = TextEditingController(text: '1.00');
  final _effectiveFromController = TextEditingController(text: _todayIso());
  PayType _payType = PayType.monthlySalary;

  @override
  void dispose() {
    _amountController.dispose();
    _unitsController.dispose();
    _effectiveFromController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _SheetFrame(
      title: l10n.addCompensationPlanTitle(widget.employee.fullName),
      children: [
        DropdownButtonFormField<PayType>(
          initialValue: _payType,
          decoration: InputDecoration(labelText: l10n.payTypeField),
          items: [
            for (final type in PayType.values)
              DropdownMenuItem(
                value: type,
                child: Text(_payTypeLabel(l10n, type)),
              ),
          ],
          onChanged: (value) {
            if (value != null) {
              setState(() => _payType = value);
            }
          },
        ),
        TextField(
          controller: _amountController,
          decoration: InputDecoration(labelText: l10n.payAmountField),
          keyboardType: TextInputType.number,
        ),
        TextField(
          controller: _unitsController,
          decoration: InputDecoration(labelText: l10n.payUnitsField),
          keyboardType: TextInputType.number,
        ),
        TextField(
          controller: _effectiveFromController,
          decoration: InputDecoration(labelText: l10n.payEffectiveFromField),
          keyboardType: TextInputType.datetime,
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
    if (_amountController.text.trim().isEmpty) {
      return;
    }
    final saved = await widget.viewModel.createCompensationPlan(
      CompensationPlanDraft(
        employeeId: widget.employee.id,
        payType: _payType,
        amount: _amountController.text.trim(),
        expectedUnitsPerPeriod: _unitsController.text.trim(),
        effectiveFrom: _effectiveFromController.text.trim(),
      ),
    );
    if (saved && mounted) {
      widget.onCreated();
    }
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
  final _periodStartController = TextEditingController(text: _todayIso());
  final _periodEndController = TextEditingController(text: _todayIso());
  final _unitsController = TextEditingController(text: '1.00');
  Employee? _employee;

  @override
  void dispose() {
    _periodStartController.dispose();
    _periodEndController.dispose();
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
        TextField(
          controller: _periodStartController,
          decoration: InputDecoration(labelText: l10n.payrollPeriodStartField),
          keyboardType: TextInputType.datetime,
        ),
        TextField(
          controller: _periodEndController,
          decoration: InputDecoration(labelText: l10n.payrollPeriodEndField),
          keyboardType: TextInputType.datetime,
        ),
        TextField(
          controller: _unitsController,
          decoration: InputDecoration(labelText: l10n.payUnitsField),
          keyboardType: TextInputType.number,
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
        periodStart: _periodStartController.text.trim(),
        periodEnd: _periodEndController.text.trim(),
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

String _todayIso() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
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

String _payrollStatusLabel(AppLocalizations l10n, PayrollStatus status) {
  return switch (status) {
    PayrollStatus.draft => l10n.payrollStatusDraft,
    PayrollStatus.approved => l10n.payrollStatusApproved,
    PayrollStatus.paid => l10n.payrollStatusPaid,
    PayrollStatus.voided => l10n.payrollStatusVoid,
  };
}
