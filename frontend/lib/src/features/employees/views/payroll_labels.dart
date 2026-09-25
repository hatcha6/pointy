import 'package:flutter/material.dart';

import '../../../core/parsing.dart';
import 'package:intl/intl.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/employee.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';

String employeeStatusLabel(AppLocalizations l10n, EmployeeStatus status) {
  return switch (status) {
    EmployeeStatus.active => l10n.employeeStatusActive,
    EmployeeStatus.onLeave => l10n.employeeStatusOnLeave,
    EmployeeStatus.inactive => l10n.employeeStatusInactive,
    EmployeeStatus.terminated => l10n.employeeStatusTerminated,
  };
}

Color employeeStatusColor(BuildContext context, EmployeeStatus status) {
  final colors = context.pointyColors;
  return switch (status) {
    EmployeeStatus.active => colors.success,
    EmployeeStatus.onLeave => colors.warning,
    EmployeeStatus.inactive => colors.mutedInk,
    EmployeeStatus.terminated => colors.danger,
  };
}

String employmentTypeLabel(AppLocalizations l10n, EmploymentType type) {
  return switch (type) {
    EmploymentType.fullTime => l10n.employmentTypeFullTime,
    EmploymentType.partTime => l10n.employmentTypePartTime,
    EmploymentType.contractor => l10n.employmentTypeContractor,
    EmploymentType.seasonal => l10n.employmentTypeSeasonal,
    EmploymentType.intern => l10n.employmentTypeIntern,
    EmploymentType.other => l10n.employmentTypeOther,
  };
}

String salaryTypeLabel(AppLocalizations l10n, SalaryType type) {
  return switch (type) {
    SalaryType.monthlyFixed => l10n.salaryTypeMonthlyFixed,
    SalaryType.weeklyFixed => l10n.salaryTypeWeeklyFixed,
    SalaryType.dailyRate => l10n.salaryTypeDailyRate,
    SalaryType.hourlyRate => l10n.salaryTypeHourlyRate,
    SalaryType.perShift => l10n.salaryTypePerShift,
    SalaryType.salesCommissionOnly => l10n.salaryTypeSalesCommissionOnly,
    SalaryType.monthlyFixedPlusSalesCommission =>
      l10n.salaryTypeMonthlyFixedPlusSalesCommission,
    SalaryType.operationsCommissionOnly =>
      l10n.salaryTypeOperationsCommissionOnly,
    SalaryType.monthlyFixedPlusOperationsCommission =>
      l10n.salaryTypeMonthlyFixedPlusOperationsCommission,
    SalaryType.contractFixed => l10n.salaryTypeContractFixed,
    SalaryType.customFixed => l10n.salaryTypeCustomFixed,
  };
}

String salaryTypeHelper(AppLocalizations l10n, SalaryType type) {
  return switch (type) {
    SalaryType.monthlyFixed => l10n.salaryTypeMonthlyFixedHelper,
    SalaryType.weeklyFixed => l10n.salaryTypeWeeklyFixedHelper,
    SalaryType.dailyRate => l10n.salaryTypeDailyRateHelper,
    SalaryType.hourlyRate => l10n.salaryTypeHourlyRateHelper,
    SalaryType.perShift => l10n.salaryTypePerShiftHelper,
    SalaryType.salesCommissionOnly => l10n.salaryTypeSalesCommissionOnlyHelper,
    SalaryType.monthlyFixedPlusSalesCommission =>
      l10n.salaryTypeMonthlyFixedPlusSalesCommissionHelper,
    SalaryType.operationsCommissionOnly =>
      l10n.salaryTypeOperationsCommissionOnlyHelper,
    SalaryType.monthlyFixedPlusOperationsCommission =>
      l10n.salaryTypeMonthlyFixedPlusOperationsCommissionHelper,
    SalaryType.contractFixed => l10n.salaryTypeContractFixedHelper,
    SalaryType.customFixed => l10n.salaryTypeCustomFixedHelper,
  };
}

String amountFieldLabel(AppLocalizations l10n, SalaryType type) {
  return switch (type) {
    SalaryType.monthlyFixed => l10n.monthlyBaseSalaryField,
    SalaryType.weeklyFixed => l10n.weeklyAmountField,
    SalaryType.dailyRate => l10n.dailyRateField,
    SalaryType.hourlyRate => l10n.hourlyRateField,
    SalaryType.perShift => l10n.shiftRateField,
    SalaryType.monthlyFixedPlusSalesCommission => l10n.monthlyBaseSalaryField,
    SalaryType.monthlyFixedPlusOperationsCommission =>
      l10n.monthlyBaseSalaryField,
    SalaryType.contractFixed => l10n.contractAmountField,
    SalaryType.customFixed => l10n.customAmountField,
    SalaryType.salesCommissionOnly => l10n.compensationAmountField,
    SalaryType.operationsCommissionOnly => l10n.compensationAmountField,
  };
}

String amountFieldHelper(AppLocalizations l10n, SalaryType type) {
  return switch (type) {
    SalaryType.monthlyFixed => l10n.monthlyBaseSalaryHelper,
    SalaryType.monthlyFixedPlusSalesCommission => l10n.monthlyBaseSalaryHelper,
    SalaryType.monthlyFixedPlusOperationsCommission =>
      l10n.monthlyBaseSalaryHelper,
    _ => salaryTypeHelper(l10n, type),
  };
}

String expectedUnitsHelper(AppLocalizations l10n, SalaryType type) {
  return switch (type) {
    SalaryType.weeklyFixed => l10n.expectedWeeksPerPeriodHelper,
    SalaryType.dailyRate => l10n.expectedDaysPerPeriodHelper,
    SalaryType.hourlyRate => l10n.expectedHoursPerPeriodHelper,
    SalaryType.perShift => l10n.expectedShiftsPerPeriodHelper,
    _ => '',
  };
}

String defaultUnitsForType(SalaryType type) {
  return switch (type) {
    SalaryType.weeklyFixed => '4.00',
    SalaryType.dailyRate => '22.00',
    SalaryType.hourlyRate => '160.00',
    SalaryType.perShift => '22.00',
    _ => '1.00',
  };
}

String payTypeLabel(AppLocalizations l10n, PayType type) {
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

String payrollPeriodLabel(AppLocalizations l10n, PayrollRun run) {
  final start = run.periodStart == null
      ? l10n.missingDateLabel
      : formatDate(run.periodStart!);
  final end = run.periodEnd == null
      ? l10n.missingDateLabel
      : formatDate(run.periodEnd!);
  return l10n.payrollPeriodSubtitle(start, end);
}

String payrollMonthLabel(BuildContext context, DateTime date) {
  final locale = Localizations.localeOf(context).toString();
  return DateFormat('MMMM yyyy', locale).format(date);
}

int payrollPeriodDays(PayrollRun run) {
  final start = run.periodStart;
  final end = run.periodEnd;
  if (start == null || end == null || end.isBefore(start)) {
    return 0;
  }
  return end.difference(start).inDays + 1;
}

String dateIso(DateTime date) {
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

String decimalInput(double value) {
  return value.toStringAsFixed(2);
}

String decimalPayload(String value) {
  return decimalValue(value).toStringAsFixed(2);
}

double decimalValue(String value) {
  return parseDecimalOr(value);
}

double roundMoney(double value) {
  return double.parse(value.toStringAsFixed(2));
}

String payrollLinePayLabel(AppLocalizations l10n, PayrollLine line) {
  final salaryType = line.salaryType;
  if (salaryType != null) {
    return salaryTypeLabel(l10n, salaryType);
  }
  final payType = line.payType;
  if (payType != null) {
    return payTypeLabel(l10n, payType);
  }
  return l10n.payrollLineManualPayLabel;
}

String payrollEmployeeLineTitle(AppLocalizations l10n, PayrollLine line) {
  return line.employeeName.trim().isEmpty
      ? l10n.payrollEmployeeFallbackLabel(line.employeeId)
      : line.employeeName.trim();
}

String compensationPlanLabel(AppLocalizations l10n, CompensationPlan plan) {
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
        salaryTypeLabel(l10n, salaryType),
        formatMoney(plan.amount),
        plan.expectedUnitsPerPeriod.toStringAsFixed(2),
      ),
      SalaryType.salesCommissionOnly || SalaryType.operationsCommissionOnly =>
        l10n.employeeCommissionOnlyPlanLabel(
          plan.commissionPercent.toStringAsFixed(2),
        ),
      SalaryType.monthlyFixedPlusSalesCommission ||
      SalaryType.monthlyFixedPlusOperationsCommission =>
        l10n.employeeMonthlyFixedPlusCommissionPlanLabel(
          formatMoney(plan.amount),
          plan.commissionPercent.toStringAsFixed(2),
        ),
      SalaryType.contractFixed ||
      SalaryType.customFixed => l10n.employeePayPlanLabel(
        salaryTypeLabel(l10n, salaryType),
        formatMoney(plan.amount),
      ),
    };
  }
  final baseLabel = l10n.employeePayPlanLabel(
    payTypeLabel(l10n, plan.payType),
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

String payrollStatusLabel(AppLocalizations l10n, PayrollStatus status) {
  return switch (status) {
    PayrollStatus.draft => l10n.payrollStatusDraft,
    PayrollStatus.approved => l10n.payrollStatusApproved,
    PayrollStatus.paid => l10n.payrollStatusPaid,
    PayrollStatus.voided => l10n.payrollStatusVoid,
  };
}

Color payrollStatusColor(BuildContext context, PayrollStatus status) {
  final colors = context.pointyColors;
  return switch (status) {
    PayrollStatus.draft => colors.warning,
    PayrollStatus.approved => colors.primaryStrong,
    PayrollStatus.paid => colors.success,
    PayrollStatus.voided => colors.mutedInk,
  };
}

IconData payrollStatusIcon(PayrollStatus status) {
  return switch (status) {
    PayrollStatus.draft => Icons.edit_note_outlined,
    PayrollStatus.approved => Icons.verified_outlined,
    PayrollStatus.paid => Icons.task_alt_outlined,
    PayrollStatus.voided => Icons.block_outlined,
  };
}

String loanStatusLabel(AppLocalizations l10n, EmployeeLoanStatus status) {
  return switch (status) {
    EmployeeLoanStatus.requested => l10n.employeeLoanStatusRequested,
    EmployeeLoanStatus.approved => l10n.employeeLoanStatusApproved,
    EmployeeLoanStatus.rejected => l10n.employeeLoanStatusRejected,
    EmployeeLoanStatus.cancelled => l10n.employeeLoanStatusCancelled,
    EmployeeLoanStatus.paid => l10n.employeeLoanStatusPaid,
  };
}

Color loanStatusColor(BuildContext context, EmployeeLoanStatus status) {
  final colors = context.pointyColors;
  return switch (status) {
    EmployeeLoanStatus.requested => colors.warning,
    EmployeeLoanStatus.approved => colors.primaryStrong,
    EmployeeLoanStatus.rejected => colors.danger,
    EmployeeLoanStatus.cancelled => colors.mutedInk,
    EmployeeLoanStatus.paid => colors.success,
  };
}

IconData loanStatusIcon(EmployeeLoanStatus status) {
  return switch (status) {
    EmployeeLoanStatus.requested => Icons.hourglass_top_outlined,
    EmployeeLoanStatus.approved => Icons.verified_outlined,
    EmployeeLoanStatus.rejected => Icons.cancel_outlined,
    EmployeeLoanStatus.cancelled => Icons.block_outlined,
    EmployeeLoanStatus.paid => Icons.task_alt_outlined,
  };
}

String payrollAdjustmentDirectionLabel(
  AppLocalizations l10n,
  String direction,
) {
  return switch (direction) {
    'addition' => l10n.payrollAdjustmentAddition,
    'deduction' => l10n.payrollAdjustmentDeduction,
    _ => l10n.payrollAdjustmentOther,
  };
}

String payrollAdjustmentTypeLabel(AppLocalizations l10n, String type) {
  return switch (type) {
    'bonus' => l10n.payrollAdjustmentBonus,
    'commission' => l10n.payrollAdjustmentCommission,
    'overtime' => l10n.payrollAdjustmentOvertime,
    'reimbursement' => l10n.payrollAdjustmentReimbursement,
    'advance' => l10n.payrollAdjustmentAdvance,
    'loan' => l10n.payrollAdjustmentLoan,
    'absence' => l10n.payrollAdjustmentAbsence,
    'penalty' => l10n.payrollAdjustmentPenalty,
    'staff_purchase' => l10n.payrollAdjustmentStaffPurchase,
    'account_balance' => l10n.payrollAdjustmentAccountBalance,
    _ => l10n.payrollAdjustmentOther,
  };
}

/// What to show beside an adjustment's amount: the invoice a staff purchase
/// takes, the balance entry an account-balance row settles, otherwise whatever
/// note the row carries.
String payrollAdjustmentNote(
  AppLocalizations l10n,
  PayrollAdjustment adjustment,
) {
  final receiptNumber = adjustment.orderReceiptNumber.trim();
  if (adjustment.isStaffPurchase && receiptNumber.isNotEmpty) {
    return l10n.payrollStaffPurchaseInvoice(receiptNumber);
  }
  final entryNumber = adjustment.balanceEntryNumber.trim();
  if (adjustment.isAccountBalance && entryNumber.isNotEmpty) {
    return l10n.payrollAccountBalanceEntry(entryNumber);
  }
  return adjustment.notes.trim();
}

String operationsCommissionBaseLabel(
  AppLocalizations l10n,
  OperationsCommissionBase base,
) {
  return switch (base) {
    OperationsCommissionBase.approvedPrice =>
      l10n.operationsCommissionBaseApprovedPrice,
    OperationsCommissionBase.labor => l10n.operationsCommissionBaseLabor,
    OperationsCommissionBase.orderTotal =>
      l10n.operationsCommissionBaseOrderTotal,
  };
}

String operationsCommissionBaseHelper(
  AppLocalizations l10n,
  OperationsCommissionBase base,
) {
  return switch (base) {
    OperationsCommissionBase.approvedPrice =>
      l10n.operationsCommissionBaseApprovedPriceHelper,
    OperationsCommissionBase.labor => l10n.operationsCommissionBaseLaborHelper,
    OperationsCommissionBase.orderTotal =>
      l10n.operationsCommissionBaseOrderTotalHelper,
  };
}
