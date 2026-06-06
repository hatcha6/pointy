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

  @override
  void dispose() {
    _baseSalaryController.dispose();
    _commissionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _SheetFrame(
      title: l10n.addCompensationPlanTitle(widget.employee.fullName),
      children: [
        TextField(
          controller: _baseSalaryController,
          decoration: InputDecoration(
            labelText: l10n.monthlyBaseSalaryField,
            helperText: l10n.monthlyBaseSalaryHelper,
          ),
          keyboardType: TextInputType.number,
          inputFormatters: [DecimalTextInputFormatter()],
        ),
        TextField(
          controller: _commissionController,
          decoration: InputDecoration(
            labelText: l10n.salesCommissionPercentField,
            helperText: l10n.salesCommissionPercentHelper,
            suffixText: '%',
          ),
          keyboardType: TextInputType.number,
          inputFormatters: [DecimalTextInputFormatter()],
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
    if (_baseSalaryController.text.trim().isEmpty) {
      return;
    }
    final saved = await widget.viewModel.createCompensationPlan(
      CompensationPlanDraft(
        employeeId: widget.employee.id,
        amount: _baseSalaryController.text.trim(),
        commissionPercent: _commissionController.text.trim().isEmpty
            ? '0.00'
            : _commissionController.text.trim(),
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

String _compensationPlanLabel(AppLocalizations l10n, CompensationPlan plan) {
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
