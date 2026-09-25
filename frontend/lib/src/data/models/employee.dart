enum EmployeeStatus {
  active,
  onLeave,
  inactive,
  terminated;

  static EmployeeStatus fromJson(Object? value) {
    return switch (value?.toString()) {
      'active' => EmployeeStatus.active,
      'on_leave' => EmployeeStatus.onLeave,
      'inactive' => EmployeeStatus.inactive,
      'terminated' => EmployeeStatus.terminated,
      _ => EmployeeStatus.active,
    };
  }

  String toJson() {
    return switch (this) {
      EmployeeStatus.active => 'active',
      EmployeeStatus.onLeave => 'on_leave',
      EmployeeStatus.inactive => 'inactive',
      EmployeeStatus.terminated => 'terminated',
    };
  }
}

enum EmploymentType {
  fullTime,
  partTime,
  contractor,
  seasonal,
  intern,
  other;

  static EmploymentType fromJson(Object? value) {
    return switch (value?.toString()) {
      'full_time' => EmploymentType.fullTime,
      'part_time' => EmploymentType.partTime,
      'contractor' => EmploymentType.contractor,
      'seasonal' => EmploymentType.seasonal,
      'intern' => EmploymentType.intern,
      'other' => EmploymentType.other,
      _ => EmploymentType.fullTime,
    };
  }

  String toJson() {
    return switch (this) {
      EmploymentType.fullTime => 'full_time',
      EmploymentType.partTime => 'part_time',
      EmploymentType.contractor => 'contractor',
      EmploymentType.seasonal => 'seasonal',
      EmploymentType.intern => 'intern',
      EmploymentType.other => 'other',
    };
  }
}

enum PayType {
  monthlySalary,
  weeklySalary,
  dailyRate,
  hourly,
  perShift,
  commission,
  contract,
  other;

  static PayType fromJson(Object? value) {
    return switch (value?.toString()) {
      'monthly_salary' => PayType.monthlySalary,
      'weekly_salary' => PayType.weeklySalary,
      'daily_rate' => PayType.dailyRate,
      'hourly' => PayType.hourly,
      'per_shift' => PayType.perShift,
      'commission' => PayType.commission,
      'contract' => PayType.contract,
      'other' => PayType.other,
      _ => PayType.monthlySalary,
    };
  }

  String toJson() {
    return switch (this) {
      PayType.monthlySalary => 'monthly_salary',
      PayType.weeklySalary => 'weekly_salary',
      PayType.dailyRate => 'daily_rate',
      PayType.hourly => 'hourly',
      PayType.perShift => 'per_shift',
      PayType.commission => 'commission',
      PayType.contract => 'contract',
      PayType.other => 'other',
    };
  }
}

enum SalaryType {
  monthlyFixed,
  weeklyFixed,
  dailyRate,
  hourlyRate,
  perShift,
  salesCommissionOnly,
  monthlyFixedPlusSalesCommission,
  operationsCommissionOnly,
  monthlyFixedPlusOperationsCommission,
  contractFixed,
  customFixed;

  static SalaryType? fromJson(Object? value) {
    return switch (value?.toString()) {
      'monthly_fixed' => SalaryType.monthlyFixed,
      'weekly_fixed' => SalaryType.weeklyFixed,
      'daily_rate' => SalaryType.dailyRate,
      'hourly_rate' => SalaryType.hourlyRate,
      'per_shift' => SalaryType.perShift,
      'sales_commission_only' => SalaryType.salesCommissionOnly,
      'monthly_fixed_plus_sales_commission' =>
        SalaryType.monthlyFixedPlusSalesCommission,
      'operations_commission_only' => SalaryType.operationsCommissionOnly,
      'monthly_fixed_plus_operations_commission' =>
        SalaryType.monthlyFixedPlusOperationsCommission,
      'contract_fixed' => SalaryType.contractFixed,
      'custom_fixed' => SalaryType.customFixed,
      _ => null,
    };
  }

  String toJson() {
    return switch (this) {
      SalaryType.monthlyFixed => 'monthly_fixed',
      SalaryType.weeklyFixed => 'weekly_fixed',
      SalaryType.dailyRate => 'daily_rate',
      SalaryType.hourlyRate => 'hourly_rate',
      SalaryType.perShift => 'per_shift',
      SalaryType.salesCommissionOnly => 'sales_commission_only',
      SalaryType.monthlyFixedPlusSalesCommission =>
        'monthly_fixed_plus_sales_commission',
      SalaryType.operationsCommissionOnly => 'operations_commission_only',
      SalaryType.monthlyFixedPlusOperationsCommission =>
        'monthly_fixed_plus_operations_commission',
      SalaryType.contractFixed => 'contract_fixed',
      SalaryType.customFixed => 'custom_fixed',
    };
  }

  PayType get payType {
    return switch (this) {
      SalaryType.salesCommissionOnly => PayType.commission,
      SalaryType.operationsCommissionOnly => PayType.commission,
      SalaryType.monthlyFixedPlusOperationsCommission => PayType.monthlySalary,
      SalaryType.monthlyFixed => PayType.monthlySalary,
      SalaryType.weeklyFixed => PayType.weeklySalary,
      SalaryType.dailyRate => PayType.dailyRate,
      SalaryType.hourlyRate => PayType.hourly,
      SalaryType.perShift => PayType.perShift,
      SalaryType.monthlyFixedPlusSalesCommission => PayType.monthlySalary,
      SalaryType.contractFixed => PayType.contract,
      SalaryType.customFixed => PayType.other,
    };
  }
}

enum OperationsCommissionBase {
  approvedPrice,
  labor,
  orderTotal;

  static OperationsCommissionBase fromJson(Object? value) {
    return switch (value?.toString()) {
      'labor' => OperationsCommissionBase.labor,
      'order_total' => OperationsCommissionBase.orderTotal,
      _ => OperationsCommissionBase.approvedPrice,
    };
  }

  String toJson() {
    return switch (this) {
      OperationsCommissionBase.approvedPrice => 'approved_price',
      OperationsCommissionBase.labor => 'labor',
      OperationsCommissionBase.orderTotal => 'order_total',
    };
  }
}

enum PayrollStatus {
  draft,
  approved,
  paid,
  voided;

  bool get canApprove => this == PayrollStatus.draft;
  bool get canPay => this == PayrollStatus.approved;

  static PayrollStatus fromJson(Object? value) {
    return switch (value?.toString()) {
      'draft' => PayrollStatus.draft,
      'approved' => PayrollStatus.approved,
      'paid' => PayrollStatus.paid,
      'void' => PayrollStatus.voided,
      _ => PayrollStatus.draft,
    };
  }
}

enum EmployeeLoanStatus {
  requested,
  approved,
  rejected,
  cancelled,
  paid;

  bool get canReview => this == EmployeeLoanStatus.requested;

  static EmployeeLoanStatus fromJson(Object? value) {
    return switch (value?.toString()) {
      'requested' => EmployeeLoanStatus.requested,
      'approved' => EmployeeLoanStatus.approved,
      'rejected' => EmployeeLoanStatus.rejected,
      'cancelled' => EmployeeLoanStatus.cancelled,
      'paid' => EmployeeLoanStatus.paid,
      _ => EmployeeLoanStatus.requested,
    };
  }

  String toJson() {
    return switch (this) {
      EmployeeLoanStatus.requested => 'requested',
      EmployeeLoanStatus.approved => 'approved',
      EmployeeLoanStatus.rejected => 'rejected',
      EmployeeLoanStatus.cancelled => 'cancelled',
      EmployeeLoanStatus.paid => 'paid',
    };
  }
}

class CompensationPlan {
  const CompensationPlan({
    required this.id,
    required this.employeeId,
    required this.payType,
    this.salaryType,
    required this.amount,
    required this.effectiveFrom,
    this.commissionPercent = 0,
    this.operationsCommissionBase = OperationsCommissionBase.approvedPrice,
    this.overtimeMultiplier = 1.5,
    this.standardDailyHours = 8,
    this.currency = 'LYD',
    this.expectedUnitsPerPeriod = 1,
    this.effectiveTo,
    this.isActive = true,
  });

  final int id;
  final int employeeId;
  final PayType payType;
  final SalaryType? salaryType;
  final double amount;
  final double commissionPercent;
  final OperationsCommissionBase operationsCommissionBase;
  final double overtimeMultiplier;
  final double standardDailyHours;
  final String currency;
  final double expectedUnitsPerPeriod;
  final DateTime? effectiveFrom;
  final DateTime? effectiveTo;
  final bool isActive;

  factory CompensationPlan.fromJson(Map<String, Object?> json) {
    return CompensationPlan(
      id: _intFromJson(json['id']),
      employeeId: _intFromJson(json['employee']),
      payType: PayType.fromJson(json['pay_type']),
      salaryType: SalaryType.fromJson(json['salary_type']),
      amount: _doubleFromJson(json['amount']),
      commissionPercent: _doubleFromJson(json['commission_percent']),
      operationsCommissionBase: OperationsCommissionBase.fromJson(
        json['operations_commission_base'],
      ),
      overtimeMultiplier: _doubleFromJson(
        json['overtime_multiplier'],
        fallback: 1.5,
      ),
      standardDailyHours: _doubleFromJson(
        json['standard_daily_hours'],
        fallback: 8,
      ),
      currency: json['currency']?.toString() ?? 'LYD',
      expectedUnitsPerPeriod: _doubleFromJson(
        json['expected_units_per_period'],
        fallback: 1,
      ),
      effectiveFrom: _dateFromJson(json['effective_from']),
      effectiveTo: _dateFromJson(json['effective_to']),
      isActive: json['is_active'] is bool
          ? json['is_active'] as bool
          : json['is_active']?.toString() != 'false',
    );
  }
}

class Employee {
  const Employee({
    required this.id,
    required this.employeeNumber,
    required this.fullName,
    required this.status,
    required this.employmentType,
    required this.hireDate,
    this.phone = '',
    this.email = '',
    this.jobTitle = '',
    this.department = '',
    this.terminationDate,
    this.userId,
    this.userUsername = '',
    this.hasSystemAccess = false,
    this.activeCompensationPlan,
    this.payrollTotal = 0,
  });

  final int id;
  final String employeeNumber;
  final String fullName;
  final String phone;
  final String email;
  final String jobTitle;
  final String department;
  final EmployeeStatus status;
  final EmploymentType employmentType;
  final DateTime? hireDate;
  final DateTime? terminationDate;
  final int? userId;
  final String userUsername;
  final bool hasSystemAccess;
  final CompensationPlan? activeCompensationPlan;
  final double payrollTotal;

  factory Employee.fromJson(Map<String, Object?> json) {
    final plan = json['active_compensation_plan'];
    return Employee(
      id: _intFromJson(json['id']),
      employeeNumber: json['employee_number']?.toString() ?? '',
      fullName: json['full_name']?.toString() ?? '',
      phone: json['phone']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      jobTitle: json['job_title']?.toString() ?? '',
      department: json['department']?.toString() ?? '',
      status: EmployeeStatus.fromJson(json['status']),
      employmentType: EmploymentType.fromJson(json['employment_type']),
      hireDate: _dateFromJson(json['hire_date']),
      terminationDate: _dateFromJson(json['termination_date']),
      userId: json['user'] == null ? null : _intFromJson(json['user']),
      userUsername: json['user_username']?.toString() ?? '',
      hasSystemAccess: json['has_system_access'] is bool
          ? json['has_system_access'] as bool
          : json['user'] != null,
      activeCompensationPlan: plan is Map<String, Object?>
          ? CompensationPlan.fromJson(plan)
          : null,
      payrollTotal: _doubleFromJson(json['payroll_total']),
    );
  }
}

class EmployeePage {
  const EmployeePage({required this.employees, required this.hasMore});

  final List<Employee> employees;
  final bool hasMore;

  factory EmployeePage.fromAny(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      final results = decoded['results'];
      return EmployeePage(
        employees: results is List<Object?>
            ? results
                  .whereType<Map<String, Object?>>()
                  .map(Employee.fromJson)
                  .toList(growable: false)
            : const [],
        hasMore: decoded['next'] != null,
      );
    }
    return const EmployeePage(employees: [], hasMore: false);
  }
}

class EmployeeLoan {
  const EmployeeLoan({
    required this.id,
    required this.employeeId,
    required this.status,
    required this.amount,
    required this.monthlyDeduction,
    required this.outstandingBalance,
    required this.deductedAmount,
    this.employeeName = '',
    this.employeeNumber = '',
    this.requestedByUsername = '',
    this.reviewedByUsername = '',
    this.purpose = '',
    this.reviewNotes = '',
    this.reviewedAt,
    this.paidAt,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final int employeeId;
  final String employeeName;
  final String employeeNumber;
  final EmployeeLoanStatus status;
  final double amount;
  final double monthlyDeduction;
  final double outstandingBalance;
  final double deductedAmount;
  final String requestedByUsername;
  final String reviewedByUsername;
  final String purpose;
  final String reviewNotes;
  final DateTime? reviewedAt;
  final DateTime? paidAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory EmployeeLoan.fromJson(Map<String, Object?> json) {
    return EmployeeLoan(
      id: _intFromJson(json['id']),
      employeeId: _intFromJson(json['employee']),
      employeeName: json['employee_name']?.toString() ?? '',
      employeeNumber: json['employee_number']?.toString() ?? '',
      status: EmployeeLoanStatus.fromJson(json['status']),
      amount: _doubleFromJson(json['amount']),
      monthlyDeduction: _doubleFromJson(json['monthly_deduction']),
      outstandingBalance: _doubleFromJson(json['outstanding_balance']),
      deductedAmount: _doubleFromJson(json['deducted_amount']),
      requestedByUsername: json['requested_by_username']?.toString() ?? '',
      reviewedByUsername: json['reviewed_by_username']?.toString() ?? '',
      purpose: json['purpose']?.toString() ?? '',
      reviewNotes: json['review_notes']?.toString() ?? '',
      reviewedAt: _dateFromJson(json['reviewed_at']),
      paidAt: _dateFromJson(json['paid_at']),
      createdAt: _dateFromJson(json['created_at']),
      updatedAt: _dateFromJson(json['updated_at']),
    );
  }
}

class EmployeeLoanPage {
  const EmployeeLoanPage({required this.loans, required this.hasMore});

  final List<EmployeeLoan> loans;
  final bool hasMore;

  factory EmployeeLoanPage.fromAny(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      final results = decoded['results'];
      return EmployeeLoanPage(
        loans: results is List<Object?>
            ? results
                  .whereType<Map<String, Object?>>()
                  .map(EmployeeLoan.fromJson)
                  .toList(growable: false)
            : const [],
        hasMore: decoded['next'] != null,
      );
    }
    return const EmployeeLoanPage(loans: [], hasMore: false);
  }
}

class MyEmployeeLoans {
  const MyEmployeeLoans({this.employee, required this.loans});

  final Employee? employee;
  final List<EmployeeLoan> loans;

  factory MyEmployeeLoans.fromJson(Map<String, Object?> json) {
    final employee = json['employee'];
    final loans = json['loans'];
    return MyEmployeeLoans(
      employee: employee is Map<String, Object?>
          ? Employee.fromJson(employee)
          : null,
      loans: loans is List<Object?>
          ? loans
                .whereType<Map<String, Object?>>()
                .map(EmployeeLoan.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

class EmployeeLoanRequestDraft {
  const EmployeeLoanRequestDraft({
    required this.amount,
    required this.monthlyDeduction,
    this.purpose = '',
  });

  final String amount;
  final String monthlyDeduction;
  final String purpose;

  Map<String, Object?> toJson() {
    return {
      'amount': amount,
      'monthly_deduction': monthlyDeduction,
      if (purpose.trim().isNotEmpty) 'purpose': purpose.trim(),
    };
  }
}

class PayrollRun {
  const PayrollRun({
    required this.id,
    required this.runNumber,
    required this.status,
    required this.periodStart,
    required this.periodEnd,
    required this.netTotal,
    this.paymentDate,
    this.notes = '',
    this.grossTotal = 0,
    this.additionsTotal = 0,
    this.deductionsTotal = 0,
    this.lineCount = 0,
    this.lines = const [],
    this.approvedByUsername = '',
    this.paidByUsername = '',
    this.approvedAt,
    this.paidAt,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final String runNumber;
  final PayrollStatus status;
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final DateTime? paymentDate;
  final String notes;
  final double grossTotal;
  final double additionsTotal;
  final double deductionsTotal;
  final double netTotal;
  final int lineCount;
  final List<PayrollLine> lines;
  final String approvedByUsername;
  final String paidByUsername;
  final DateTime? approvedAt;
  final DateTime? paidAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory PayrollRun.fromJson(Map<String, Object?> json) {
    final lines = json['lines'];
    return PayrollRun(
      id: _intFromJson(json['id']),
      runNumber: json['run_number']?.toString() ?? '',
      status: PayrollStatus.fromJson(json['status']),
      periodStart: _dateFromJson(json['period_start']),
      periodEnd: _dateFromJson(json['period_end']),
      paymentDate: _dateFromJson(json['payment_date']),
      notes: json['notes']?.toString() ?? '',
      grossTotal: _doubleFromJson(json['gross_total']),
      additionsTotal: _doubleFromJson(json['additions_total']),
      deductionsTotal: _doubleFromJson(json['deductions_total']),
      netTotal: _doubleFromJson(json['net_total']),
      lineCount: _intFromJson(json['line_count']),
      lines: lines is List<Object?>
          ? lines
                .whereType<Map<String, Object?>>()
                .map(PayrollLine.fromJson)
                .toList(growable: false)
          : const [],
      approvedByUsername: json['approved_by_username']?.toString() ?? '',
      paidByUsername: json['paid_by_username']?.toString() ?? '',
      approvedAt: _dateFromJson(json['approved_at']),
      paidAt: _dateFromJson(json['paid_at']),
      createdAt: _dateFromJson(json['created_at']),
      updatedAt: _dateFromJson(json['updated_at']),
    );
  }
}

class PayrollLine {
  const PayrollLine({
    required this.id,
    required this.employeeId,
    this.employeeName = '',
    this.employeeNumber = '',
    this.compensationPlanId,
    this.payType,
    this.salaryType,
    this.description = '',
    this.units = 0,
    this.rate = 0,
    this.grossAmount = 0,
    this.absenceDays = 0,
    this.absenceDayRate = 0,
    this.absenceDeductionAmount = 0,
    this.overtimeHours = 0,
    this.overtimeHourlyRate = 0,
    this.overtimeMultiplier = 1.5,
    this.overtimeAmount = 0,
    this.raiseAmount = 0,
    this.manualAdditionAmount = 0,
    this.manualDeductionAmount = 0,
    this.additionsAmount = 0,
    this.deductionsAmount = 0,
    this.netAmount = 0,
    this.notes = '',
    this.adjustments = const [],
  });

  final int id;
  final int employeeId;
  final String employeeName;
  final String employeeNumber;
  final int? compensationPlanId;
  final PayType? payType;
  final SalaryType? salaryType;
  final String description;
  final double units;
  final double rate;
  final double grossAmount;
  final double absenceDays;
  final double absenceDayRate;
  final double absenceDeductionAmount;
  final double overtimeHours;
  final double overtimeHourlyRate;
  final double overtimeMultiplier;
  final double overtimeAmount;
  final double raiseAmount;
  final double manualAdditionAmount;
  final double manualDeductionAmount;
  final double additionsAmount;
  final double deductionsAmount;
  final double netAmount;
  final String notes;
  final List<PayrollAdjustment> adjustments;

  factory PayrollLine.fromJson(Map<String, Object?> json) {
    final adjustments = json['adjustments'];
    return PayrollLine(
      id: _intFromJson(json['id']),
      employeeId: _intFromJson(json['employee']),
      employeeName: json['employee_name']?.toString() ?? '',
      employeeNumber: json['employee_number']?.toString() ?? '',
      compensationPlanId: json['compensation_plan'] == null
          ? null
          : _intFromJson(json['compensation_plan']),
      payType: json['pay_type'] == null
          ? null
          : PayType.fromJson(json['pay_type']),
      salaryType: SalaryType.fromJson(json['salary_type']),
      description: json['description']?.toString() ?? '',
      units: _doubleFromJson(json['units']),
      rate: _doubleFromJson(json['rate']),
      grossAmount: _doubleFromJson(json['gross_amount']),
      absenceDays: _doubleFromJson(json['absence_days']),
      absenceDayRate: _doubleFromJson(json['absence_day_rate']),
      absenceDeductionAmount: _doubleFromJson(json['absence_deduction_amount']),
      overtimeHours: _doubleFromJson(json['overtime_hours']),
      overtimeHourlyRate: _doubleFromJson(json['overtime_hourly_rate']),
      overtimeMultiplier: _doubleFromJson(
        json['overtime_multiplier'],
        fallback: 1.5,
      ),
      overtimeAmount: _doubleFromJson(json['overtime_amount']),
      raiseAmount: _doubleFromJson(json['raise_amount']),
      manualAdditionAmount: _doubleFromJson(json['manual_addition_amount']),
      manualDeductionAmount: _doubleFromJson(json['manual_deduction_amount']),
      additionsAmount: _doubleFromJson(json['additions_amount']),
      deductionsAmount: _doubleFromJson(json['deductions_amount']),
      netAmount: _doubleFromJson(json['net_amount']),
      notes: json['notes']?.toString() ?? '',
      adjustments: adjustments is List<Object?>
          ? adjustments
                .whereType<Map<String, Object?>>()
                .map(PayrollAdjustment.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

class PayrollAdjustment {
  const PayrollAdjustment({
    required this.id,
    required this.direction,
    required this.adjustmentType,
    required this.amount,
    this.notes = '',
    this.orderReceiptNumber = '',
  });

  final int id;
  final String direction;
  final String adjustmentType;
  final double amount;
  final String notes;

  /// The staff-purchase invoice this deduction takes, by its printed number.
  /// Empty for every other kind of adjustment.
  final String orderReceiptNumber;

  /// Something the employee bought on their staff account, taken from pay.
  /// The server gives it way first when the rest of the line leaves less pay.
  bool get isStaffPurchase =>
      adjustmentType == 'staff_purchase' && direction == 'deduction';

  factory PayrollAdjustment.fromJson(Map<String, Object?> json) {
    return PayrollAdjustment(
      id: _intFromJson(json['id']),
      direction: json['direction']?.toString() ?? '',
      adjustmentType: json['adjustment_type']?.toString() ?? '',
      amount: _doubleFromJson(json['amount']),
      notes: json['notes']?.toString() ?? '',
      orderReceiptNumber: json['order_receipt_number']?.toString() ?? '',
    );
  }
}

class PayrollRunPage {
  const PayrollRunPage({required this.runs, required this.hasMore});

  final List<PayrollRun> runs;
  final bool hasMore;

  factory PayrollRunPage.fromAny(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      final results = decoded['results'];
      return PayrollRunPage(
        runs: results is List<Object?>
            ? results
                  .whereType<Map<String, Object?>>()
                  .map(PayrollRun.fromJson)
                  .toList(growable: false)
            : const [],
        hasMore: decoded['next'] != null,
      );
    }
    return const PayrollRunPage(runs: [], hasMore: false);
  }
}

class EmployeeDraft {
  const EmployeeDraft({
    required this.fullName,
    required this.hireDate,
    this.phone = '',
    this.email = '',
    this.jobTitle = '',
    this.department = '',
    this.employmentType = EmploymentType.fullTime,
    this.status = EmployeeStatus.active,
    this.userId,
  });

  final String fullName;
  final String phone;
  final String email;
  final String jobTitle;
  final String department;
  final EmploymentType employmentType;
  final EmployeeStatus status;
  final String hireDate;
  final int? userId;

  Map<String, Object?> toJson() {
    return {
      'full_name': fullName,
      'phone': phone,
      'email': email,
      'job_title': jobTitle,
      'department': department,
      'employment_type': employmentType.toJson(),
      'status': status.toJson(),
      'hire_date': hireDate,
      if (userId != null) 'user': userId,
    };
  }
}

class CompensationPlanDraft {
  const CompensationPlanDraft({
    required this.employeeId,
    required this.salaryType,
    required this.amount,
    this.commissionPercent = '0.00',
    this.operationsCommissionBase = OperationsCommissionBase.approvedPrice,
    this.overtimeMultiplier = '1.50',
    this.standardDailyHours = '8.00',
    this.expectedUnitsPerPeriod = '1.00',
    this.notes = '',
  });

  final int employeeId;
  final SalaryType salaryType;
  final String amount;
  final String commissionPercent;
  final OperationsCommissionBase operationsCommissionBase;
  final String overtimeMultiplier;
  final String standardDailyHours;
  final String expectedUnitsPerPeriod;
  final String notes;
  PayType get payType => salaryType.payType;

  Map<String, Object?> toJson() {
    return {
      'employee': employeeId,
      'pay_type': payType.toJson(),
      'salary_type': salaryType.toJson(),
      'amount': amount,
      'commission_percent': commissionPercent,
      'operations_commission_base': operationsCommissionBase.toJson(),
      'overtime_multiplier': overtimeMultiplier,
      'standard_daily_hours': standardDailyHours,
      'expected_units_per_period': expectedUnitsPerPeriod,
      if (notes.trim().isNotEmpty) 'notes': notes.trim(),
      'is_active': true,
    };
  }
}

class PayrollDraftResult {
  const PayrollDraftResult({required this.created, this.payrollRun});

  final bool created;
  final PayrollRun? payrollRun;

  factory PayrollDraftResult.fromJson(Map<String, Object?> json) {
    final run = json['payroll_run'];
    return PayrollDraftResult(
      created: json['created'] == true,
      payrollRun: run is Map<String, Object?> ? PayrollRun.fromJson(run) : null,
    );
  }
}

class PayrollLineAdjustmentDraft {
  const PayrollLineAdjustmentDraft({
    this.absenceDays = '0.00',
    this.overtimeHours = '0.00',
    this.raiseAmount = '0.00',
    this.manualAdditionAmount = '0.00',
    this.manualDeductionAmount = '0.00',
    this.notes = '',
  });

  final String absenceDays;
  final String overtimeHours;
  final String raiseAmount;
  final String manualAdditionAmount;
  final String manualDeductionAmount;
  final String notes;

  Map<String, Object?> toJson() {
    return {
      'absence_days': absenceDays,
      'overtime_hours': overtimeHours,
      'raise_amount': raiseAmount,
      'manual_addition_amount': manualAdditionAmount,
      'manual_deduction_amount': manualDeductionAmount,
      'notes': notes.trim(),
    };
  }
}

enum PayrollBulkAdjustmentType {
  addition,
  deduction,
  overtime;

  String get direction {
    return switch (this) {
      PayrollBulkAdjustmentType.addition => 'addition',
      PayrollBulkAdjustmentType.deduction => 'deduction',
      PayrollBulkAdjustmentType.overtime => 'addition',
    };
  }

  String get adjustmentType {
    return switch (this) {
      PayrollBulkAdjustmentType.addition => 'bonus',
      PayrollBulkAdjustmentType.deduction => 'other',
      PayrollBulkAdjustmentType.overtime => 'overtime',
    };
  }
}

class PayrollBulkAdjustmentDraft {
  const PayrollBulkAdjustmentDraft({
    required this.payrollLineIds,
    required this.type,
    required this.amount,
    this.notes = '',
  });

  final List<int> payrollLineIds;
  final PayrollBulkAdjustmentType type;
  final String amount;
  final String notes;

  Map<String, Object?> toJson() {
    return {
      'line_ids': payrollLineIds,
      'direction': type.direction,
      'adjustment_type': type.adjustmentType,
      'amount': amount,
      if (notes.trim().isNotEmpty) 'notes': notes.trim(),
    };
  }
}

class PayrollRunDraft {
  const PayrollRunDraft({
    required this.periodStart,
    required this.periodEnd,
    required this.lines,
    this.notes = '',
  });

  final String periodStart;
  final String periodEnd;
  final List<PayrollLineDraft> lines;
  final String notes;

  Map<String, Object?> toJson() {
    return {
      'period_start': periodStart,
      'period_end': periodEnd,
      'notes': notes,
      'lines': lines.map((line) => line.toJson()).toList(growable: false),
    };
  }
}

class PayrollLineDraft {
  const PayrollLineDraft({
    required this.employeeId,
    this.compensationPlanId,
    this.units = '1.00',
    this.rate = '0.00',
    this.description = '',
  });

  final int employeeId;
  final int? compensationPlanId;
  final String units;
  final String rate;
  final String description;

  Map<String, Object?> toJson() {
    return {
      'employee': employeeId,
      if (compensationPlanId != null) 'compensation_plan': compensationPlanId,
      'units': units,
      'rate': rate,
      'description': description,
    };
  }
}

int _intFromJson(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _doubleFromJson(Object? value, {double fallback = 0}) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

DateTime? _dateFromJson(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) {
    return null;
  }
  return DateTime.tryParse(text);
}
