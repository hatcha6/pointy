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
import 'package:pointy_frontend/src/features/employees/views/payroll_run_details_screen.dart';

import '../../../shared/fake_app_navigation.dart';

/// A failed load of any payroll list used to be a dead end: the panel named the
/// failure and offered nothing to do about it, so a cashier or manager whose
/// LAN blipped had to back out of the workspace and come in again. Each list
/// now offers the retry its own reload method already supported.
void main() {
  testWidgets('a failed payroll-runs load offers a retry that refills it', (
    tester,
  ) async {
    final api = _payrollApi(failFirstRequestTo: 'payroll-runs/');
    final viewModel = EmployeePayrollViewModel(EmployeeRepository(api.service));

    await tester.pumpWidget(_payrollApp(viewModel, api.service));
    await tester.pumpAndSettle();

    // The failure is visible and, crucially, it is not a dead end.
    expect(find.text('تعذر تحميل مسيرات الرواتب.'), findsOneWidget);
    final retry = find.byKey(const ValueKey('payroll_runs_retry_button'));
    expect(retry, findsOneWidget);
    expect(find.text('إعادة المحاولة'), findsWidgets);

    final before = api.requestCount('payroll-runs/');
    // The month workflow card sits above the history list, so the retry can
    // start below the fold on a short viewport.
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    await tester.tap(retry);
    await tester.pumpAndSettle();

    // Exactly one more fetch, and the list is populated.
    expect(api.requestCount('payroll-runs/'), before + 1);
    expect(find.text('تعذر تحميل مسيرات الرواتب.'), findsNothing);
    expect(find.textContaining('PR7', skipOffstage: false), findsWidgets);
  });

  testWidgets('a failed employees load offers a retry that refills it', (
    tester,
  ) async {
    final api = _payrollApi(failFirstRequestTo: 'employees/');
    final viewModel = EmployeePayrollViewModel(EmployeeRepository(api.service));

    await tester.pumpWidget(_payrollApp(viewModel, api.service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('الموظفون'));
    await tester.pumpAndSettle();

    expect(find.text('تعذر تحميل الموظفين.'), findsOneWidget);
    final retry = find.byKey(const ValueKey('employees_retry_button'));
    expect(retry, findsOneWidget);

    final before = api.requestCount('employees/');
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(api.requestCount('employees/'), before + 1);
    expect(find.text('تعذر تحميل الموظفين.'), findsNothing);
    expect(find.text('سالم'), findsWidgets);
  });

  testWidgets('a failed loans load offers a retry that refills it', (
    tester,
  ) async {
    final api = _payrollApi(failFirstRequestTo: 'employee-loans/');
    final viewModel = EmployeePayrollViewModel(EmployeeRepository(api.service));

    await tester.pumpWidget(_payrollApp(viewModel, api.service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('طلبات السلفة'));
    await tester.pumpAndSettle();

    expect(find.text('تعذر تحميل طلبات السلفة.'), findsOneWidget);
    final retry = find.byKey(const ValueKey('employee_loans_retry_button'));
    expect(retry, findsOneWidget);

    final before = api.requestCount('employee-loans/');
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(api.requestCount('employee-loans/'), before + 1);
    expect(find.text('تعذر تحميل طلبات السلفة.'), findsNothing);
    expect(find.text('مريم'), findsWidgets);
  });

  testWidgets('a failed run-details load offers a retry that loads the run', (
    tester,
  ) async {
    final api = _payrollApi(failFirstRequestTo: 'payroll-runs/7/');
    final viewModel = EmployeePayrollViewModel(EmployeeRepository(api.service));
    final capabilities = AuthorizationCapabilities.forUser(
      PosUser.fromJson(_userJson()),
    );

    await tester.pumpWidget(
      _localizedApp(
        PayrollRunDetailsScreen(
          viewModel: viewModel,
          attendanceViewModel: AttendanceViewModel(
            AttendanceRepository(api.service),
          ),
          capabilities: capabilities,
          initialRun: PayrollRun.fromJson(_runJson()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('تعذر تحميل تفاصيل مسير الرواتب.'), findsOneWidget);
    final retry = find.byKey(const ValueKey('payroll_details_retry_button'));
    expect(retry, findsOneWidget);

    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(find.text('تعذر تحميل تفاصيل مسير الرواتب.'), findsNothing);
    expect(find.text('سالم'), findsWidgets);
  });
}

/// A payroll backend that fails the *first* request to one path and serves
/// normally afterwards — the shape of a LAN blip, which is what makes the
/// retry the correct affordance rather than a permanent error.
class _PayrollApi {
  _PayrollApi(this.failFirstRequestTo);

  final String failFirstRequestTo;
  final Map<String, int> _counts = {};
  late final PosApiService service = PosApiService(client: MockClient(_handle));

  int requestCount(String path) => _counts[path] ?? 0;

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;

    String? matched;
    for (final known in const [
      'payroll-runs/7/',
      'payroll-runs/',
      'employees/',
      'employee-loans/',
    ]) {
      if (path.endsWith('/$known')) {
        matched = known;
        break;
      }
    }

    if (matched != null) {
      _counts[matched] = (_counts[matched] ?? 0) + 1;
      if (matched == failFirstRequestTo && _counts[matched] == 1) {
        return http.Response('', 500);
      }
    }

    switch (matched) {
      case 'payroll-runs/7/':
        return _json(_runJson());
      case 'payroll-runs/':
        return _json({
          'results': [_runJson()],
          'next': null,
        });
      case 'employees/':
        return _json({
          'results': [_employeeJson()],
          'next': null,
        });
      case 'employee-loans/':
        return _json({
          'results': [_loanJson()],
          'next': null,
        });
    }

    if (path.endsWith('/attendance/connection/')) {
      return _json({'base_url': '', 'is_enabled': false});
    }
    return http.Response('', 404);
  }
}

_PayrollApi _payrollApi({required String failFirstRequestTo}) =>
    _PayrollApi(failFirstRequestTo);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Widget _localizedApp(Widget home) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  );
}

Widget _payrollApp(
  EmployeePayrollViewModel viewModel,
  PosApiService apiService,
) {
  final user = PosUser.fromJson(_userJson());
  final capabilities = AuthorizationCapabilities.forUser(user);

  return _localizedApp(
    EmployeePayrollScreen(
      viewModel: viewModel,
      attendanceViewModel: AttendanceViewModel(
        AttendanceRepository(apiService),
      ),
      userRepository: UserRepository(apiService),
      capabilities: capabilities,
      navigation: FakeAppNavigation(
        currentUser: user,
        capabilities: capabilities,
      ),
    ),
  );
}

Map<String, Object?> _userJson() => {
  'id': 1,
  'username': 'manager',
  'display_name': 'مدير النظام',
  'email': '',
  'role': 'manager',
  'permissions': const [
    'employees.view_employee',
    'employees.add_employee',
    'employees.view_payrollrun',
    'employees.add_payrollrun',
    'employees.change_payrollrun',
    'employees.view_employeeloan',
  ],
};

String _isoDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

Map<String, Object?> _runJson() {
  final now = DateTime.now();
  return {
    'id': 7,
    'run_number': 'PR7',
    'status': 'draft',
    'period_start': _isoDate(DateTime(now.year, now.month)),
    'period_end': _isoDate(DateTime(now.year, now.month + 1, 0)),
    'payment_date': null,
    'notes': '',
    'gross_total': '500.00',
    'additions_total': '0.00',
    'deductions_total': '0.00',
    'net_total': '500.00',
    'line_count': 1,
    'lines': [
      {
        'id': 70,
        'employee': 1,
        'employee_name': 'سالم',
        'employee_number': 'E1',
        'gross_amount': '500.00',
        'additions_total': '0.00',
        'deductions_total': '0.00',
        'net_amount': '500.00',
      },
    ],
    'approved_by_username': '',
    'paid_by_username': '',
  };
}

Map<String, Object?> _employeeJson() => {
  'id': 1,
  'employee_number': 'E1',
  'full_name': 'سالم',
  'status': 'active',
  'employment_type': 'full_time',
  'hire_date': '2025-01-01',
  'has_system_access': false,
  'payroll_total': '0.00',
  'active_compensation_plan': null,
};

Map<String, Object?> _loanJson() => {
  'id': 4,
  'employee': 1,
  'employee_name': 'مريم',
  'employee_number': 'E1',
  'status': 'requested',
  'amount': '300.00',
  'monthly_deduction': '50.00',
  'outstanding_balance': '0.00',
  'deducted_amount': '0.00',
  'requested_by_username': 'manager',
  'reviewed_by_username': '',
  'purpose': '',
  'review_notes': '',
};
