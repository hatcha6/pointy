import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/employee.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/attendance_repository.dart';
import 'package:pointy_frontend/src/data/repositories/employee_repository.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/attendance/view_models/attendance_view_model.dart';
import 'package:pointy_frontend/src/features/employees/view_models/employee_payroll_view_model.dart';
import 'package:pointy_frontend/src/features/employees/views/employee_payroll_screen.dart';
import 'package:pointy_frontend/src/features/employees/views/payroll_forms.dart';
import 'package:pointy_frontend/src/features/employees/views/payroll_run_details_screen.dart';

import '../../../shared/fake_app_navigation.dart';

/// The payroll card used to offer "prepare this month" to a shop that could
/// not prepare anything: employees without a salary plan were only found out
/// after a round trip, adding an employee never led on to their salary, and
/// last month's run — the one actually due in the first days of a month —
/// was not on the card at all.
void main() {
  // Early October: September's salaries are what is due.
  DateTime clock() => DateTime(2026, 10, 3, 10);

  testWidgets('no employee with a plan: prepare waits, and says who to fix', (
    tester,
  ) async {
    _bigScreen(tester);
    final api = _PayrollApi(
      employees: [_employee(1, 'سالم'), _employee(2, 'مريم')],
    );
    await _pump(tester, api, clock);

    final prepare = tester.widget<FilledButton>(
      find.byKey(const ValueKey('payroll_prepare_month_button')),
    );
    expect(prepare.onPressed, isNull);
    expect(
      find.text('حدّد راتب موظف واحد على الأقل لتتمكن من تجهيز المسير.'),
      findsOneWidget,
    );
    expect(find.text('0 من 2 لديهم خطة راتب لهذا الشهر'), findsOneWidget);
    expect(find.byKey(const ValueKey('payroll_missing_plan_1')), findsOne);
    expect(find.byKey(const ValueKey('payroll_missing_plan_2')), findsOne);

    await tester.tap(find.byKey(const ValueKey('payroll_set_salary_2')));
    await tester.pumpAndSettle();
    expect(find.byType(CompensationPlanForm), findsOneWidget);
    expect(find.textContaining('مريم'), findsWidgets);
    // Opened from the card, not after adding: nothing to put off.
    expect(
      find.byKey(const ValueKey('compensation_plan_skip_button')),
      findsNothing,
    );
    expect(api.draftBodies, isEmpty);
  });

  testWidgets('some without a plan: prepare goes ahead and names the gap', (
    tester,
  ) async {
    _bigScreen(tester);
    final api = _PayrollApi(
      employees: [
        _employee(1, 'سالم', plan: _plan(1)),
        _employee(2, 'مريم'),
      ],
    );
    await _pump(tester, api, clock);

    final prepare = tester.widget<FilledButton>(
      find.byKey(const ValueKey('payroll_prepare_month_button')),
    );
    expect(prepare.onPressed, isNotNull);
    expect(find.text('1 من 2 لديهم خطة راتب لهذا الشهر'), findsOneWidget);
    expect(find.text('موظف واحد بدون خطة لن يُدرج في المسير.'), findsOneWidget);
    expect(find.byKey(const ValueKey('payroll_missing_plan_1')), findsNothing);
  });

  testWidgets('everyone ready: no checklist, just the button', (tester) async {
    _bigScreen(tester);
    final api = _PayrollApi(employees: [_employee(1, 'سالم', plan: _plan(1))]);
    await _pump(tester, api, clock);

    expect(find.byKey(const ValueKey('payroll_readiness_plans')), findsNothing);
    expect(
      find.byKey(const ValueKey('payroll_prepare_skips_hint')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('payroll_prepare_month_button')),
    );
    await tester.pumpAndSettle();
    expect(api.draftBodies, [
      {'period_start': '2026-10-01', 'period_end': '2026-10-31'},
    ]);
  });

  testWidgets('adding the first employee goes straight on to their salary', (
    tester,
  ) async {
    _bigScreen(tester);
    final api = _PayrollApi(employees: []);
    await _pump(tester, api, clock);

    await tester.tap(
      find.byKey(const ValueKey('payroll_readiness_add_employee_button')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CreateEmployeeForm), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'سالم');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();

    expect(api.createdEmployees, hasLength(1));
    expect(find.byType(CompensationPlanForm), findsOneWidget);
    expect(
      find.byKey(const ValueKey('compensation_plan_intro')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('compensation_plan_skip_button')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CompensationPlanForm), findsNothing);
    // Back on the card, the new employee is the one it asks about.
    expect(find.byKey(const ValueKey('payroll_missing_plan_9')), findsOne);
  });

  testWidgets('last month still unpaid: the card is about last month', (
    tester,
  ) async {
    _bigScreen(tester);
    final api = _PayrollApi(
      employees: [_employee(1, 'سالم', plan: _plan(1))],
      runs: [_run(7, 'draft', start: '2026-09-01', end: '2026-09-30')],
    );
    final viewModel = await _pump(tester, api, clock);

    expect(find.textContaining('سبتمبر'), findsWidgets);
    expect(
      find.byKey(const ValueKey('payroll_review_approve_button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('payroll_month_next_button')));
    await tester.pumpAndSettle();
    expect(viewModel.payrollMonthPeriod.start, DateTime(2026, 10));
    expect(
      find.byKey(const ValueKey('payroll_prepare_month_button')),
      findsOneWidget,
    );
    // Payroll is never prepared ahead.
    final next = tester.widget<IconButton>(
      find.byKey(const ValueKey('payroll_month_next_button')),
    );
    expect(next.onPressed, isNull);
  });

  testWidgets('last month paid: the card is about this month', (tester) async {
    _bigScreen(tester);
    final api = _PayrollApi(
      employees: [_employee(1, 'سالم', plan: _plan(1))],
      runs: [_run(7, 'paid', start: '2026-09-01', end: '2026-09-30')],
    );
    final viewModel = await _pump(tester, api, clock);

    expect(viewModel.payrollMonthPeriod.start, DateTime(2026, 10));
  });

  testWidgets('an earlier month drafts that month', (tester) async {
    _bigScreen(tester);
    final api = _PayrollApi(employees: [_employee(1, 'سالم', plan: _plan(1))]);
    await _pump(tester, api, clock);

    await tester.tap(
      find.byKey(const ValueKey('payroll_month_previous_button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('payroll_prepare_month_button')),
    );
    await tester.pumpAndSettle();

    expect(api.draftBodies, [
      {'period_start': '2026-09-01', 'period_end': '2026-09-30'},
    ]);
  });

  testWidgets('a plan that starts after the month is named, and fixed by '
      'dating a plan from the hire date', (tester) async {
    _bigScreen(tester);
    final api = _PayrollApi(
      employees: [
        _employee(1, 'سالم', plan: _plan(1)),
        _employee(2, 'مريم', plan: _plan(2, from: '2026-10-02')),
      ],
    );
    await _pump(tester, api, clock);

    await tester.tap(
      find.byKey(const ValueKey('payroll_month_previous_button')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('payroll_missing_plan_2')), findsOne);
    expect(find.textContaining('بعد هذا الشهر'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('payroll_set_salary_2')));
    await tester.pumpAndSettle();
    // Her plan starts after she was hired: the sheet dates the new one from
    // the hire date, so the month she was missing from is covered.
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey('compensation_plan_effective_from_field'),
        ),
        matching: find.textContaining('2025'),
      ),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField).at(0), '900');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();

    expect(api.createdPlans.single['effective_from'], '2025-01-01');
    expect(api.createdPlans.single['amount'], '900');
  });

  testWidgets('a new hire this month is named: paid from their start day', (
    tester,
  ) async {
    _bigScreen(tester);
    final api = _PayrollApi(
      employees: [
        _employee(1, 'سالم', plan: _plan(1)),
        _employee(2, 'مريم', plan: _plan(2), hired: '2026-10-02'),
      ],
    );
    await _pump(tester, api, clock);

    final hint = find.byKey(const ValueKey('payroll_prepare_prorated_hint'));
    expect(hint, findsOneWidget);
    final text = tester.widget<Text>(hint).data!;
    expect(text, contains('مريم'));
    expect(text, isNot(contains('سالم')));
  });

  testWidgets('a custom run covers the chosen employees, units where paid '
      'per unit', (tester) async {
    _bigScreen(tester);
    final api = _PayrollApi(
      employees: [
        _employee(1, 'سالم', plan: _plan(1)),
        _employee(
          2,
          'مريم',
          plan: _plan(2, salaryType: 'daily_rate', units: '22.00'),
        ),
        _employee(3, 'علي', plan: _plan(3)),
      ],
    );
    await _pump(tester, api, clock);

    await tester.tap(find.byKey(const ValueKey('payroll_custom_run_button')));
    await tester.pumpAndSettle();

    // Nothing ticked yet: saving asks for a choice and sends nothing.
    await tester.tap(find.byKey(const ValueKey('custom_payroll_save_button')));
    await tester.pumpAndSettle();
    expect(find.text('اختر موظفاً واحداً على الأقل.'), findsOneWidget);
    expect(api.createdRuns, isEmpty);

    await tester.tap(find.byKey(const ValueKey('custom_payroll_employee_1')));
    await tester.tap(find.byKey(const ValueKey('custom_payroll_employee_2')));
    await tester.pumpAndSettle();
    // A fixed salary has no units to ask for; a daily rate asks for days.
    expect(find.byKey(const ValueKey('custom_payroll_units_1')), findsNothing);
    expect(find.byKey(const ValueKey('custom_payroll_units_2')), findsOne);
    expect(find.text('عدد الأيام'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('custom_payroll_units_2')),
      '10',
    );
    await tester.tap(find.byKey(const ValueKey('custom_payroll_save_button')));
    await tester.pumpAndSettle();

    expect(api.createdRuns, hasLength(1));
    final body = api.createdRuns.single;
    // The card's month, whole: not "the 1st to today".
    expect(body['period_start'], '2026-10-01');
    expect(body['period_end'], '2026-10-31');
    final lines = (body['lines'] as List).cast<Map<String, Object?>>();
    expect(lines.map((line) => line['employee']), [1, 2]);
    expect(lines.map((line) => line['units']), ['1.00', '10']);
  });

  testWidgets('a prorated line says so, and the correction is sent', (
    tester,
  ) async {
    _bigScreen(tester);
    final api = _PayrollApi(
      employees: [_employee(1, 'مريم', plan: _plan(1), hired: '2026-09-15')],
      runDetail: {
        ..._run(7, 'draft', start: '2026-09-01', end: '2026-09-30'),
        'lines': [
          {
            'id': 70,
            'employee': 1,
            'employee_name': 'مريم',
            'gross_amount': '1500.00',
            'days_not_employed': '14.00',
            'not_employed_deduction_amount': '700.00',
            'deductions_amount': '700.00',
            'net_amount': '800.00',
          },
        ],
      },
    );
    final viewModel = EmployeePayrollViewModel(
      EmployeeRepository(api.service),
      clock: clock,
    );
    final user = PosUser.fromJson(_userJson());
    final capabilities = AuthorizationCapabilities.forUser(user);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: PayrollRunDetailsScreen(
          viewModel: viewModel,
          attendanceViewModel: AttendanceViewModel(
            AttendanceRepository(api.service),
          ),
          capabilities: capabilities,
          initialRun: PayrollRun.fromJson(api.runDetail!),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final pill = find.byKey(const ValueKey('payroll_line_not_employed_70'));
    expect(pill, findsOneWidget);
    expect(
      find.descendant(of: pill, matching: find.textContaining('14')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('payroll_line_tile_70')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('payroll_line_days_not_employed_field')),
      '10',
    );
    await tester.tap(find.text('حفظ التعديل'));
    await tester.pumpAndSettle();

    expect(api.lineEdits.single['days_not_employed'], '10.00');
  });
}

void _bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<EmployeePayrollViewModel> _pump(
  WidgetTester tester,
  _PayrollApi api,
  DateTime Function() clock,
) async {
  final viewModel = EmployeePayrollViewModel(
    EmployeeRepository(api.service),
    clock: clock,
  );
  final user = PosUser.fromJson(_userJson());
  final capabilities = AuthorizationCapabilities.forUser(user);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: EmployeePayrollScreen(
        viewModel: viewModel,
        attendanceViewModel: AttendanceViewModel(
          AttendanceRepository(api.service),
        ),
        userRepository: UserRepository(api.service),
        capabilities: capabilities,
        navigation: FakeAppNavigation(
          currentUser: user,
          capabilities: capabilities,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return viewModel;
}

class _PayrollApi {
  _PayrollApi({required this.employees, this.runs = const [], this.runDetail});

  final List<Map<String, Object?>> employees;
  final List<Map<String, Object?>> runs;
  final Map<String, Object?>? runDetail;
  final List<Map<String, Object?>> lineEdits = [];
  final List<Map<String, Object?>> draftBodies = [];
  final List<Map<String, Object?>> createdEmployees = [];
  final List<Map<String, Object?>> createdRuns = [];
  final List<Map<String, Object?>> createdPlans = [];
  late final PosApiService service = PosApiService(client: MockClient(_handle));

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    final isPost = request.method == 'POST';
    if (path.contains('/payroll-runs/7/lines/')) {
      lineEdits.add(_body(request));
      return _json(runDetail!);
    }
    if (path.endsWith('/payroll-runs/7/')) {
      return _json(runDetail!);
    }
    if (path.endsWith('/payroll-runs/draft-monthly/')) {
      draftBodies.add(_body(request));
      return _json({'created': false, 'payroll_run': null});
    }
    if (path.endsWith('/payroll-runs/')) {
      if (isPost) {
        final body = _body(request);
        createdRuns.add(body);
        return _json(
          _run(
            50,
            'draft',
            start: body['period_start']! as String,
            end: body['period_end']! as String,
          ),
        );
      }
      return _json({'results': runs, 'next': null});
    }
    if (path.endsWith('/employees/')) {
      if (isPost) {
        final body = _body(request);
        createdEmployees.add(body);
        final created = _employee(9, body['full_name']! as String);
        employees.insert(0, created);
        return _json(created);
      }
      return _json({'results': employees, 'next': null});
    }
    if (path.endsWith('/compensation-plans/') && isPost) {
      final body = _body(request);
      createdPlans.add(body);
      return _json({...body, 'id': 99});
    }
    if (path.endsWith('/employee-loans/')) {
      return _json({'results': const [], 'next': null});
    }
    if (path.endsWith('/attendance/connection/')) {
      return _json({'base_url': '', 'is_enabled': false});
    }
    return http.Response('', 404);
  }

  Map<String, Object?> _body(http.Request request) =>
      Map<String, Object?>.from(jsonDecode(request.body) as Map);
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, Object?> _employee(
  int id,
  String name, {
  Map<String, Object?>? plan,
  String hired = '2025-01-01',
}) => {
  'id': id,
  'employee_number': 'E$id',
  'full_name': name,
  'status': 'active',
  'employment_type': 'full_time',
  'hire_date': hired,
  'has_system_access': false,
  'payroll_total': '0.00',
  'active_compensation_plan': plan,
};

Map<String, Object?> _plan(
  int employeeId, {
  String from = '2026-01-01',
  String salaryType = 'monthly_fixed',
  String units = '1.00',
}) => {
  'id': employeeId * 10,
  'employee': employeeId,
  'pay_type': 'monthly_salary',
  'salary_type': salaryType,
  'amount': '500.00',
  'expected_units_per_period': units,
  'effective_from': from,
  'is_active': true,
};

Map<String, Object?> _run(
  int id,
  String status, {
  required String start,
  required String end,
}) => {
  'id': id,
  'run_number': 'PR$id',
  'status': status,
  'period_start': start,
  'period_end': end,
  'payment_date': null,
  'notes': '',
  'gross_total': '500.00',
  'additions_total': '0.00',
  'deductions_total': '0.00',
  'net_total': '500.00',
  'line_count': 1,
  'lines': const [],
  'approved_by_username': '',
  'paid_by_username': '',
};

Map<String, Object?> _userJson() => {
  'id': 1,
  'username': 'manager',
  'display_name': 'مدير النظام',
  'email': '',
  'role': 'manager',
  'permissions': const [
    'employees.view_employee',
    'employees.add_employee',
    'employees.change_employee',
    'employees.add_compensationplan',
    'employees.view_payrollrun',
    'employees.add_payrollrun',
    'employees.change_payrollrun',
    'employees.view_employeeloan',
  ],
};
