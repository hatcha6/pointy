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

class CompensationPlan {
  const CompensationPlan({
    required this.id,
    required this.employeeId,
    required this.payType,
    required this.amount,
    required this.effectiveFrom,
    this.commissionPercent = 0,
    this.currency = 'LYD',
    this.expectedUnitsPerPeriod = 1,
    this.effectiveTo,
    this.isActive = true,
  });

  final int id;
  final int employeeId;
  final PayType payType;
  final double amount;
  final double commissionPercent;
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
      amount: _doubleFromJson(json['amount']),
      commissionPercent: _doubleFromJson(json['commission_percent']),
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

class PayrollRun {
  const PayrollRun({
    required this.id,
    required this.runNumber,
    required this.status,
    required this.periodStart,
    required this.periodEnd,
    required this.netTotal,
    this.paymentDate,
    this.grossTotal = 0,
    this.additionsTotal = 0,
    this.deductionsTotal = 0,
    this.lineCount = 0,
  });

  final int id;
  final String runNumber;
  final PayrollStatus status;
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final DateTime? paymentDate;
  final double grossTotal;
  final double additionsTotal;
  final double deductionsTotal;
  final double netTotal;
  final int lineCount;

  factory PayrollRun.fromJson(Map<String, Object?> json) {
    return PayrollRun(
      id: _intFromJson(json['id']),
      runNumber: json['run_number']?.toString() ?? '',
      status: PayrollStatus.fromJson(json['status']),
      periodStart: _dateFromJson(json['period_start']),
      periodEnd: _dateFromJson(json['period_end']),
      paymentDate: _dateFromJson(json['payment_date']),
      grossTotal: _doubleFromJson(json['gross_total']),
      additionsTotal: _doubleFromJson(json['additions_total']),
      deductionsTotal: _doubleFromJson(json['deductions_total']),
      netTotal: _doubleFromJson(json['net_total']),
      lineCount: _intFromJson(json['line_count']),
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
    required this.amount,
    this.payType = PayType.monthlySalary,
    this.commissionPercent = '0.00',
    this.expectedUnitsPerPeriod = '1.00',
  });

  final int employeeId;
  final PayType payType;
  final String amount;
  final String commissionPercent;
  final String expectedUnitsPerPeriod;

  Map<String, Object?> toJson() {
    return {
      'employee': employeeId,
      'pay_type': payType.toJson(),
      'amount': amount,
      'commission_percent': commissionPercent,
      'expected_units_per_period': expectedUnitsPerPeriod,
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
