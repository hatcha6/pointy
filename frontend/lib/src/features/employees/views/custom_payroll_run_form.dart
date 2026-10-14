import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/employee.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../view_models/employee_payroll_view_model.dart';
import 'payroll_forms.dart';
import 'payroll_labels.dart';

/// A payroll run for chosen employees or a period other than the card's
/// month: a leaver's last days, a late hire, a one-off. The monthly card
/// covers everyone; this is the exception, so it starts with nobody ticked.
class CustomPayrollRunForm extends StatefulWidget {
  const CustomPayrollRunForm({
    super.key,
    required this.viewModel,
    required this.onCreated,
  });

  final EmployeePayrollViewModel viewModel;
  final VoidCallback onCreated;

  @override
  State<CustomPayrollRunForm> createState() => _CustomPayrollRunFormState();
}

class _CustomPayrollRunFormState extends State<CustomPayrollRunForm> {
  late DateTime _periodStart;
  late DateTime _periodEnd;
  final Set<int> _selected = {};
  final Map<int, TextEditingController> _units = {};
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    final month = widget.viewModel.payrollMonthPeriod;
    _periodStart = month.start;
    _periodEnd = month.end;
  }

  @override
  void dispose() {
    for (final controller in _units.values) {
      controller.dispose();
    }
    super.dispose();
  }

  List<Employee> get _employees => widget.viewModel.employees
      .where((employee) => employee.activeCompensationPlan != null)
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final employees = _employees;

    return PayrollSheetFrame(
      title: l10n.customPayrollRunTitle,
      children: [
        PayrollDatePickerField(
          label: l10n.payrollPeriodStartField,
          value: _periodStart,
          onChanged: (value) {
            setState(() {
              _periodStart = value;
              if (_periodEnd.isBefore(value)) {
                // A new start month means that month's end, not one day.
                _periodEnd = DateTime(value.year, value.month + 1, 0);
              }
            });
          },
        ),
        PayrollDatePickerField(
          label: l10n.payrollPeriodEndField,
          value: _periodEnd,
          firstDate: _periodStart,
          onChanged: (value) => setState(() => _periodEnd = value),
        ),
        if (employees.isEmpty)
          PointyInlineMessage.warning(
            message: l10n.noEmployeesWithPayPlan,
            icon: Icons.info_outline,
          )
        else ...[
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.customPayrollEmployeesLabel,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('custom_payroll_select_all_button'),
                    onPressed: () => setState(
                      () => _selected.addAll(employees.map((e) => e.id)),
                    ),
                    child: Text(l10n.customPayrollSelectAllButton),
                  ),
                ],
              ),
              for (final employee in employees) _employeeTile(l10n, employee),
            ],
          ),
          if (_submitted && _selected.isEmpty)
            PointyInlineMessage.error(
              message: l10n.customPayrollNoSelectionError,
              compact: true,
            ),
        ],
        FilledButton.icon(
          key: const ValueKey('custom_payroll_save_button'),
          onPressed: widget.viewModel.isSaving || employees.isEmpty
              ? null
              : _submit,
          icon: const Icon(Icons.save_outlined),
          label: Text(l10n.saveButton),
        ),
      ],
    );
  }

  Widget _employeeTile(AppLocalizations l10n, Employee employee) {
    final plan = employee.activeCompensationPlan!;
    final selected = _selected.contains(employee.id);
    final unitsLabel = _unitsLabel(l10n, plan);
    final units = unitsLabel == null ? null : _unitsController(employee);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          key: ValueKey('custom_payroll_employee_${employee.id}'),
          value: selected,
          contentPadding: EdgeInsets.zero,
          dense: true,
          visualDensity: VisualDensity.compact,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(employee.fullName),
          onChanged: (value) => setState(() {
            if (value ?? false) {
              _selected.add(employee.id);
            } else {
              _selected.remove(employee.id);
            }
          }),
        ),
        if (selected && unitsLabel != null && units != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 48, bottom: 8),
            child: TextField(
              key: ValueKey('custom_payroll_units_${employee.id}'),
              controller: units,
              decoration: InputDecoration(labelText: unitsLabel),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [DecimalTextInputFormatter()],
            ),
          ),
      ],
    );
  }

  TextEditingController _unitsController(Employee employee) {
    return _units.putIfAbsent(
      employee.id,
      () => TextEditingController(
        text: employee.activeCompensationPlan!.expectedUnitsPerPeriod
            .toStringAsFixed(2),
      ),
    );
  }

  String _unitsFor(Employee employee) {
    final typed = _units[employee.id]?.text.trim() ?? '';
    return typed.isEmpty ? '1.00' : typed;
  }

  /// What the plan pays per unit, as the field asks for it. Null for plans
  /// whose pay is fixed for the period: the server ignores units for those.
  String? _unitsLabel(AppLocalizations l10n, CompensationPlan plan) {
    return switch (plan.salaryType) {
      SalaryType.weeklyFixed => l10n.customPayrollWeeksField,
      SalaryType.dailyRate => l10n.customPayrollDaysField,
      SalaryType.hourlyRate => l10n.customPayrollHoursField,
      SalaryType.perShift => l10n.customPayrollShiftsField,
      null => switch (plan.payType) {
        PayType.dailyRate => l10n.customPayrollDaysField,
        PayType.hourly => l10n.customPayrollHoursField,
        PayType.perShift => l10n.customPayrollShiftsField,
        PayType.other => l10n.payUnitsField,
        _ => null,
      },
      _ => null,
    };
  }

  Future<void> _submit() async {
    setState(() => _submitted = true);
    final chosen = _employees
        .where((employee) => _selected.contains(employee.id))
        .toList(growable: false);
    if (chosen.isEmpty) {
      return;
    }
    final saved = await widget.viewModel.createPayrollRun(
      PayrollRunDraft(
        periodStart: dateIso(_periodStart),
        periodEnd: dateIso(_periodEnd),
        lines: [
          for (final employee in chosen)
            PayrollLineDraft(
              employeeId: employee.id,
              compensationPlanId: employee.activeCompensationPlan!.id,
              units: _unitsFor(employee),
            ),
        ],
      ),
    );
    if (saved && mounted) {
      widget.onCreated();
    }
  }
}
