import 'package:flutter/material.dart';

import '../../../data/models/employee.dart';
import '../../../data/repositories/user_repository.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/employee_payroll_view_model.dart';
import 'custom_payroll_run_form.dart';
import 'payroll_forms.dart';

/// Adds an employee, then goes straight on to their salary plan: an employee
/// without one is left out of every payroll run, and nothing else on the
/// screen would send the manager there.
Future<void> showAddEmployeeFlow(
  BuildContext context, {
  required EmployeePayrollViewModel viewModel,
  required UserRepository userRepository,
  required bool allowOpeningBalance,
}) async {
  final employee = await showAdaptiveFormSurface<Employee>(
    context: context,
    size: AdaptiveModalSize.standard,
    builder: (sheetContext) => CreateEmployeeForm(
      viewModel: viewModel,
      userRepository: userRepository,
      allowOpeningBalance: allowOpeningBalance,
      onCreated: (employee) => Navigator.of(sheetContext).pop(employee),
    ),
  );
  if (employee == null || !context.mounted) {
    return;
  }
  await showCompensationPlanSheet(
    context,
    viewModel: viewModel,
    employee: employee,
    afterCreate: true,
  );
}

/// The salary plan sheet. [afterCreate] marks the step that follows adding
/// the employee: it says why it opened and can be put off.
Future<void> showCompensationPlanSheet(
  BuildContext context, {
  required EmployeePayrollViewModel viewModel,
  required Employee employee,
  bool afterCreate = false,
}) {
  return showAdaptiveFormSurface<void>(
    context: context,
    size: AdaptiveModalSize.standard,
    builder: (sheetContext) => CompensationPlanForm(
      viewModel: viewModel,
      employee: employee,
      onCreated: () => Navigator.of(sheetContext).pop(),
      onSkip: afterCreate ? () => Navigator.of(sheetContext).pop() : null,
    ),
  );
}

Future<void> showCustomPayrollRunSheet(
  BuildContext context, {
  required EmployeePayrollViewModel viewModel,
}) {
  return showAdaptiveFormSurface<void>(
    context: context,
    size: AdaptiveModalSize.standard,
    builder: (sheetContext) => CustomPayrollRunForm(
      viewModel: viewModel,
      onCreated: () => Navigator.of(sheetContext).pop(),
    ),
  );
}
