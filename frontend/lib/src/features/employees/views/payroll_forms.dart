import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/balance_entry.dart';
import '../../../data/models/employee.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/user_repository.dart';
import '../../../shared/async_selection/async_selection.dart';
import '../../../shared/balance_labels.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/opening_balance_fields.dart';
import '../view_models/employee_payroll_view_model.dart';
import 'payroll_labels.dart';

class CreateEmployeeForm extends StatefulWidget {
  const CreateEmployeeForm({
    super.key,
    required this.viewModel,
    required this.userRepository,
    required this.onCreated,
    this.allowOpeningBalance = false,
  });

  final EmployeePayrollViewModel viewModel;
  final UserRepository userRepository;

  /// Gets the saved employee, so the add flow can go on to their salary.
  final ValueChanged<Employee> onCreated;

  /// Offers the balance the employee arrives with — only to a user who may
  /// write one; the server checks again.
  final bool allowOpeningBalance;

  @override
  State<CreateEmployeeForm> createState() => _CreateEmployeeFormState();
}

class _CreateEmployeeFormState extends State<CreateEmployeeForm> {
  final _nameController = TextEditingController();
  final _jobController = TextEditingController();
  final _departmentController = TextEditingController();
  final _phoneController = TextEditingController();
  DateTime _hireDate = DateTime.now();
  EmploymentType _employmentType = EmploymentType.fullTime;
  AsyncSelectionOption<int>? _selectedUser;
  final _openingFormKey = GlobalKey<FormState>();
  final _openingBalance = OpeningBalanceController();
  String? _openingError;

  @override
  void dispose() {
    _nameController.dispose();
    _jobController.dispose();
    _departmentController.dispose();
    _phoneController.dispose();
    _openingBalance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PayrollSheetFrame(
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
        PayrollDatePickerField(
          label: l10n.employeeHireDateField,
          helperText: l10n.employeeHireDateHelper,
          value: _hireDate,
          lastDate: DateTime.now(),
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
                child: Text(employmentTypeLabel(l10n, type)),
              ),
          ],
          onChanged: (value) {
            if (value != null) {
              setState(() => _employmentType = value);
            }
          },
        ),
        if (widget.allowOpeningBalance)
          Form(
            key: _openingFormKey,
            child: OpeningBalanceFields(
              controller: _openingBalance,
              party: BalanceParty.employee,
              enabled: !widget.viewModel.isSaving,
            ),
          ),
        if (_openingError != null)
          PointyInlineMessage.error(message: _openingError!),
        FilledButton.icon(
          onPressed: widget.viewModel.isSaving ? null : _submit,
          icon: const Icon(Icons.save_outlined),
          label: Text(l10n.saveButton),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      return;
    }
    if (widget.allowOpeningBalance &&
        _openingBalance.enabled &&
        !(_openingFormKey.currentState?.validate() ?? true)) {
      return;
    }
    setState(() => _openingError = null);
    final opening = widget.allowOpeningBalance ? _openingBalance.draft : null;
    final saved = await widget.viewModel.createEmployee(
      EmployeeDraft(
        fullName: name,
        jobTitle: _jobController.text.trim(),
        department: _departmentController.text.trim(),
        phone: _phoneController.text.trim(),
        hireDate: dateIso(_hireDate),
        employmentType: _employmentType,
        userId: _selectedUser?.id,
        openingBalance: opening,
      ),
    );
    if (!mounted) {
      return;
    }
    final created = widget.viewModel.lastCreatedEmployee;
    if (saved && created != null) {
      widget.onCreated(created);
      return;
    }
    if (opening != null) {
      // The employee and their balance are written together, so a refused
      // balance refuses both — say which part to fix.
      final failure = classifyBalanceFailure(widget.viewModel.lastCreateError);
      if (failure != BalanceFailure.generic) {
        setState(() {
          _openingError = balanceFailureMessage(
            l10n,
            failure,
            fallback: l10n.employeePayrollSaveError,
          );
        });
      }
    }
  }

  Future<void> _pickUser() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: AsyncSelectionPickerStrings<int>(
        title: l10n.userPickerTitle,
        searchHint: l10n.userPickerSearchHint,
        emptyText: l10n.userPickerEmpty,
        clearText: l10n.userPickerClear,
        clearSearchTooltip: l10n.clearSearchTooltip,
        loadErrorText: l10n.userPickerLoadError,
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

class CompensationPlanForm extends StatefulWidget {
  const CompensationPlanForm({
    super.key,
    required this.viewModel,
    required this.employee,
    required this.onCreated,
    this.onSkip,
  });

  final EmployeePayrollViewModel viewModel;
  final Employee employee;
  final VoidCallback onCreated;

  /// Set when the sheet follows adding the employee: it then says why it
  /// opened and offers to set the salary later.
  final VoidCallback? onSkip;

  @override
  State<CompensationPlanForm> createState() => _CompensationPlanFormState();
}

class _CompensationPlanFormState extends State<CompensationPlanForm> {
  final _baseSalaryController = TextEditingController();
  final _commissionController = TextEditingController(text: '0.00');
  final _expectedUnitsController = TextEditingController(text: '1.00');
  final _overtimeMultiplierController = TextEditingController(text: '1.50');
  final _dailyHoursController = TextEditingController(text: '8.00');
  final _notesController = TextEditingController();
  SalaryType _salaryType = SalaryType.monthlyFixed;
  OperationsCommissionBase _operationsCommissionBase =
      OperationsCommissionBase.approvedPrice;
  bool _submitted = false;
  late DateTime _effectiveFrom = _defaultEffectiveFrom();

  /// A first plan starts the day the employee did, so the month they joined
  /// is paid. So does one replacing a plan that started after they were
  /// hired — that gap is what it is for. A later plan is a raise: today.
  DateTime _defaultEffectiveFrom() {
    final today = DateUtils.dateOnly(DateTime.now());
    final hired = widget.employee.hireDate;
    if (hired == null || hired.isAfter(today)) {
      return today;
    }
    final current = widget.employee.activeCompensationPlan;
    final currentFrom = current?.effectiveFrom;
    if (current == null || currentFrom == null || currentFrom.isAfter(hired)) {
      return DateUtils.dateOnly(hired);
    }
    return today;
  }

  @override
  void dispose() {
    _baseSalaryController.dispose();
    _commissionController.dispose();
    _expectedUnitsController.dispose();
    _overtimeMultiplierController.dispose();
    _dailyHoursController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PayrollSheetFrame(
      title: l10n.addCompensationPlanTitle(widget.employee.fullName),
      children: [
        if (widget.onSkip != null)
          PointyInlineMessage(
            key: const ValueKey('compensation_plan_intro'),
            message: l10n.payrollCompensationIntro(widget.employee.fullName),
            icon: Icons.payments_outlined,
          ),
        DropdownButtonFormField<SalaryType>(
          initialValue: _salaryType,
          decoration: InputDecoration(labelText: l10n.salaryTypeField),
          items: SalaryType.values
              .map(
                (type) => DropdownMenuItem(
                  value: type,
                  child: Text(salaryTypeLabel(l10n, type)),
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
                    final previousDefault = defaultUnitsForType(_salaryType);
                    _salaryType = value;
                    if (_expectedUnitsController.text.trim().isEmpty ||
                        _expectedUnitsController.text.trim() ==
                            previousDefault) {
                      _expectedUnitsController.text = defaultUnitsForType(
                        value,
                      );
                    }
                  });
                },
        ),
        PointyInlineMessage(
          message: salaryTypeHelper(l10n, _salaryType),
          icon: Icons.payments_outlined,
          compact: true,
        ),
        if (_requiresBaseSalary)
          TextField(
            controller: _baseSalaryController,
            decoration: InputDecoration(
              labelText: amountFieldLabel(l10n, _salaryType),
              helperText: amountFieldHelper(l10n, _salaryType),
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
              helperText: expectedUnitsHelper(l10n, _salaryType),
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
              labelText: _usesOperationsCommission
                  ? l10n.operationsCommissionPercentField
                  : l10n.salesCommissionPercentField,
              helperText: _usesOperationsCommission
                  ? l10n.operationsCommissionPercentHelper
                  : l10n.salesCommissionPercentHelper,
              errorText: _submitted && !_hasPositiveValue(_commissionController)
                  ? l10n.commissionRequiredError
                  : null,
              suffixText: '%',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
          ),
        if (_usesSalesCommission && !widget.employee.hasSystemAccess)
          PointyInlineMessage(
            message: l10n.salesCommissionNeedsLinkedUserWarning,
            icon: Icons.link_off_outlined,
            compact: true,
          ),
        if (_usesOperationsCommission)
          DropdownButtonFormField<OperationsCommissionBase>(
            initialValue: _operationsCommissionBase,
            decoration: InputDecoration(
              labelText: l10n.operationsCommissionBaseField,
              helperText: operationsCommissionBaseHelper(
                l10n,
                _operationsCommissionBase,
              ),
            ),
            items: OperationsCommissionBase.values
                .map(
                  (base) => DropdownMenuItem(
                    value: base,
                    child: Text(operationsCommissionBaseLabel(l10n, base)),
                  ),
                )
                .toList(),
            onChanged: (base) => setState(
              () => _operationsCommissionBase =
                  base ?? OperationsCommissionBase.approvedPrice,
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _overtimeMultiplierController,
                decoration: InputDecoration(
                  labelText: l10n.overtimeMultiplierField,
                  helperText: l10n.overtimeMultiplierHelper,
                  suffixText: '×',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [DecimalTextInputFormatter()],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _dailyHoursController,
                decoration: InputDecoration(
                  labelText: l10n.standardDailyHoursField,
                  helperText: l10n.standardDailyHoursHelper,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [DecimalTextInputFormatter()],
              ),
            ),
          ],
        ),
        PayrollDatePickerField(
          key: const ValueKey('compensation_plan_effective_from_field'),
          label: l10n.compensationEffectiveFromField,
          helperText: l10n.compensationEffectiveFromHelper,
          value: _effectiveFrom,
          lastDate: DateTime.now(),
          onChanged: (value) => setState(() => _effectiveFrom = value),
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
        if (widget.onSkip case final onSkip?)
          TextButton(
            key: const ValueKey('compensation_plan_skip_button'),
            onPressed: widget.viewModel.isSaving ? null : onSkip,
            child: Text(l10n.payrollCompensationSkipButton),
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
        operationsCommissionBase: _usesOperationsCommission
            ? _operationsCommissionBase
            : OperationsCommissionBase.approvedPrice,
        overtimeMultiplier: _overtimeMultiplierController.text.trim().isEmpty
            ? '1.50'
            : _overtimeMultiplierController.text.trim(),
        standardDailyHours: _dailyHoursController.text.trim().isEmpty
            ? '8.00'
            : _dailyHoursController.text.trim(),
        expectedUnitsPerPeriod: _requiresExpectedUnits
            ? _expectedUnitsController.text.trim()
            : '1.00',
        notes: _showsNotes ? _notesController.text.trim() : '',
        effectiveFrom: dateIso(_effectiveFrom),
      ),
    );
    if (saved && mounted) {
      widget.onCreated();
    }
  }

  bool get _requiresBaseSalary {
    return _salaryType != SalaryType.salesCommissionOnly &&
        _salaryType != SalaryType.operationsCommissionOnly;
  }

  bool get _requiresCommission {
    return _usesSalesCommission || _usesOperationsCommission;
  }

  bool get _usesSalesCommission {
    return _salaryType == SalaryType.salesCommissionOnly ||
        _salaryType == SalaryType.monthlyFixedPlusSalesCommission;
  }

  // Operations commission pays a percentage of the repairs the employee
  // completed; unlike sales commission it does not need a linked login.
  bool get _usesOperationsCommission {
    return _salaryType == SalaryType.operationsCommissionOnly ||
        _salaryType == SalaryType.monthlyFixedPlusOperationsCommission;
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

class PayrollSheetFrame extends StatelessWidget {
  const PayrollSheetFrame({
    super.key,
    required this.title,
    required this.children,
  });

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

class PayrollDatePickerField extends StatelessWidget {
  const PayrollDatePickerField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.firstDate,
    this.lastDate,
    this.helperText,
  });

  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onChanged;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final String? helperText;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      key: ValueKey('$label-${dateIso(value)}'),
      initialValue: formatDate(value),
      readOnly: true,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        helperMaxLines: 2,
        suffixIcon: const Icon(Icons.event_outlined),
      ),
      onTap: () async {
        final now = DateTime.now();
        final selected = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: firstDate ?? DateTime(now.year - 10),
          lastDate: lastDate ?? DateTime(now.year + 5, 12, 31),
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
