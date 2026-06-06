import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/employee.dart';

void main() {
  test('employee page parses system access and active compensation', () {
    final page = EmployeePage.fromAny({
      'next': '/api/employees/?page=2',
      'results': [
        {
          'id': 7,
          'employee_number': 'EMP-0007',
          'full_name': 'سارة أحمد',
          'phone': '0910000000',
          'email': 'sara@example.com',
          'job_title': 'أمين صندوق',
          'department': 'المبيعات',
          'status': 'on_leave',
          'employment_type': 'part_time',
          'hire_date': '2026-05-01',
          'termination_date': null,
          'user': 14,
          'user_username': 'sara',
          'has_system_access': true,
          'payroll_total': '1250.50',
          'active_compensation_plan': {
            'id': 33,
            'employee': 7,
            'pay_type': 'hourly',
            'amount': '12.75',
            'currency': 'LYD',
            'expected_units_per_period': '120',
            'effective_from': '2026-05-01',
            'effective_to': null,
            'is_active': true,
          },
        },
      ],
    });

    expect(page.hasMore, isTrue);
    expect(page.employees, hasLength(1));

    final employee = page.employees.single;
    expect(employee.employeeNumber, 'EMP-0007');
    expect(employee.status, EmployeeStatus.onLeave);
    expect(employee.employmentType, EmploymentType.partTime);
    expect(employee.hasSystemAccess, isTrue);
    expect(employee.userId, 14);
    expect(employee.payrollTotal, 1250.50);
    expect(employee.activeCompensationPlan?.payType, PayType.hourly);
    expect(employee.activeCompensationPlan?.salaryType, isNull);
    expect(employee.activeCompensationPlan?.amount, 12.75);
    expect(employee.activeCompensationPlan?.expectedUnitsPerPeriod, 120);
  });

  test('payroll run page parses workflow status totals and pagination', () {
    final page = PayrollRunPage.fromAny({
      'next': null,
      'results': [
        {
          'id': 9,
          'run_number': 'PAY-202606-0009',
          'status': 'approved',
          'period_start': '2026-06-01',
          'period_end': '2026-06-30',
          'payment_date': null,
          'gross_total': '1800.00',
          'additions_total': '50.00',
          'deductions_total': '25.00',
          'net_total': '1825.00',
          'line_count': 3,
        },
      ],
    });

    expect(page.hasMore, isFalse);
    final run = page.runs.single;
    expect(run.status, PayrollStatus.approved);
    expect(run.status.canApprove, isFalse);
    expect(run.status.canPay, isTrue);
    expect(run.grossTotal, 1800);
    expect(run.additionsTotal, 50);
    expect(run.deductionsTotal, 25);
    expect(run.netTotal, 1825);
    expect(run.lineCount, 3);
  });

  test('payroll run parses detail lines and adjustments', () {
    final run = PayrollRun.fromJson({
      'id': 10,
      'run_number': 'PAY-202606-0010',
      'status': 'draft',
      'period_start': '2026-06-01',
      'period_end': '2026-06-30',
      'payment_date': null,
      'notes': 'مسير تلقائي',
      'gross_total': '900.00',
      'additions_total': '20.00',
      'deductions_total': '0.00',
      'net_total': '920.00',
      'line_count': 1,
      'created_at': '2026-06-30T23:10:00Z',
      'lines': [
        {
          'id': 41,
          'employee': 7,
          'employee_name': 'سارة أحمد',
          'employee_number': 'EMP-0007',
          'compensation_plan': 33,
          'pay_type': 'monthly_salary',
          'salary_type': 'monthly_fixed_plus_sales_commission',
          'description': 'راتب شهر يونيو',
          'units': '1.00',
          'rate': '900.00',
          'gross_amount': '900.00',
          'additions_amount': '20.00',
          'deductions_amount': '0.00',
          'net_amount': '920.00',
          'notes': '',
          'adjustments': [
            {
              'id': 5,
              'direction': 'addition',
              'adjustment_type': 'commission',
              'amount': '20.00',
              'notes': '10.00% commission on 200.00 sales',
            },
          ],
        },
      ],
    });

    expect(run.lines, hasLength(1));
    expect(run.notes, 'مسير تلقائي');
    expect(run.createdAt, isNotNull);

    final line = run.lines.single;
    expect(line.employeeName, 'سارة أحمد');
    expect(line.employeeNumber, 'EMP-0007');
    expect(line.salaryType, SalaryType.monthlyFixedPlusSalesCommission);
    expect(line.payType, PayType.monthlySalary);
    expect(line.grossAmount, 900);
    expect(line.additionsAmount, 20);
    expect(line.netAmount, 920);
    expect(line.adjustments.single.adjustmentType, 'commission');
    expect(line.adjustments.single.amount, 20);
  });

  test('employee and payroll drafts serialize backend field names', () {
    final employee = EmployeeDraft(
      fullName: 'محمد علي',
      hireDate: '2026-06-01',
      employmentType: EmploymentType.contractor,
      status: EmployeeStatus.active,
      userId: 22,
    ).toJson();
    expect(employee['full_name'], 'محمد علي');
    expect(employee['employment_type'], 'contractor');
    expect(employee['user'], 22);

    final payroll = PayrollRunDraft(
      periodStart: '2026-06-01',
      periodEnd: '2026-06-30',
      lines: const [
        PayrollLineDraft(
          employeeId: 7,
          compensationPlanId: 33,
          units: '10',
          rate: '15.50',
          description: 'وردية إضافية',
        ),
      ],
    ).toJson();
    expect(payroll['period_start'], '2026-06-01');
    expect(payroll['period_end'], '2026-06-30');
    expect(payroll['lines'], [
      {
        'employee': 7,
        'compensation_plan': 33,
        'units': '10',
        'rate': '15.50',
        'description': 'وردية إضافية',
      },
    ]);

    final fixedSalary = const CompensationPlanDraft(
      employeeId: 7,
      salaryType: SalaryType.monthlyFixed,
      amount: '900.00',
    ).toJson();
    expect(fixedSalary['pay_type'], 'monthly_salary');
    expect(fixedSalary['salary_type'], 'monthly_fixed');
    expect(fixedSalary['amount'], '900.00');
    expect(fixedSalary['commission_percent'], '0.00');

    final commissionOnlySalary = const CompensationPlanDraft(
      employeeId: 7,
      salaryType: SalaryType.salesCommissionOnly,
      amount: '0.00',
      commissionPercent: '8.50',
    ).toJson();
    expect(commissionOnlySalary['pay_type'], 'commission');
    expect(commissionOnlySalary['salary_type'], 'sales_commission_only');
    expect(commissionOnlySalary['amount'], '0.00');
    expect(commissionOnlySalary['commission_percent'], '8.50');

    final fixedPlusCommissionSalary = const CompensationPlanDraft(
      employeeId: 7,
      salaryType: SalaryType.monthlyFixedPlusSalesCommission,
      amount: '900.00',
      commissionPercent: '10.00',
    ).toJson();
    expect(fixedPlusCommissionSalary['pay_type'], 'monthly_salary');
    expect(
      fixedPlusCommissionSalary['salary_type'],
      'monthly_fixed_plus_sales_commission',
    );
    expect(fixedPlusCommissionSalary['amount'], '900.00');
    expect(fixedPlusCommissionSalary['commission_percent'], '10.00');
  });
}
