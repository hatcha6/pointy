import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
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

/// "Prepare this month's payroll" on the payroll card.
///
/// REGRESSION (Annaseem, 2026-09-30 23:15). The card is titled with the month
/// the shop is in, but its button sent no period, and without one the server
/// drafts the PREVIOUS month. August had no salary plans (they were added that
/// night), so the server answered "nothing to draft" and the card showed the
/// generic "could not save" error. The manager pressed it seven times.
void main() {
  // The last evening of September, when it happened.
  DateTime clock() => DateTime(2026, 9, 30, 23, 15);

  testWidgets('it drafts the month on the card, not the month before', (
    tester,
  ) async {
    final api = _PayrollApi(draftResponse: _emptyDraft);
    final viewModel = EmployeePayrollViewModel(
      EmployeeRepository(api.service),
      clock: clock,
    );
    await tester.pumpWidget(_payrollApp(viewModel, api.service));
    await tester.pumpAndSettle();

    expect(find.textContaining('سبتمبر'), findsWidgets);
    await _prepareMonth(tester);

    expect(api.draftBodies, [
      {'period_start': '2026-09-01', 'period_end': '2026-09-30'},
    ]);
  });

  testWidgets('a month with no salary plans says so instead of failing', (
    tester,
  ) async {
    final api = _PayrollApi(draftResponse: _emptyDraft);
    final viewModel = EmployeePayrollViewModel(
      EmployeeRepository(api.service),
      clock: clock,
    );
    await tester.pumpWidget(_payrollApp(viewModel, api.service));
    await tester.pumpAndSettle();

    await _prepareMonth(tester);

    final message = find.byKey(
      const ValueKey('payroll_month_no_plans_message'),
    );
    expect(message, findsOneWidget);
    expect(
      find.descendant(
        of: message,
        matching: find.textContaining('لا يوجد موظف لديه خطة راتب سارية'),
      ),
      findsOneWidget,
    );
    // The server answered; nothing failed. The generic save error was what
    // made a manager keep pressing the button.
    expect(find.text(_saveError), findsNothing);
    expect(viewModel.hasSaveError, isFalse);
    expect(viewModel.monthDraftFoundNoPlans, isTrue);
  });

  testWidgets('a drafted month opens the run for review', (tester) async {
    final api = _PayrollApi(
      draftResponse: {'created': true, 'payroll_run': _runJson()},
    );
    final viewModel = EmployeePayrollViewModel(
      EmployeeRepository(api.service),
      clock: clock,
    );
    await tester.pumpWidget(_payrollApp(viewModel, api.service));
    await tester.pumpAndSettle();

    await _prepareMonth(tester);

    expect(find.byType(PayrollRunDetailsScreen), findsOneWidget);
    expect(viewModel.monthDraftFoundNoPlans, isFalse);
    expect(viewModel.hasSaveError, isFalse);
  });

  testWidgets('a failed request is still reported as a failure', (
    tester,
  ) async {
    final api = _PayrollApi(draftResponse: null);
    final viewModel = EmployeePayrollViewModel(
      EmployeeRepository(api.service),
      clock: clock,
    );
    await tester.pumpWidget(_payrollApp(viewModel, api.service));
    await tester.pumpAndSettle();

    await _prepareMonth(tester);

    expect(find.text(_saveError), findsOneWidget);
    expect(
      find.byKey(const ValueKey('payroll_month_no_plans_message')),
      findsNothing,
    );
  });
}

const _saveError =
    'تعذر حفظ التغيير. راجع البيانات والصلاحيات ثم حاول مرة أخرى.';

const Map<String, Object?> _emptyDraft = {
  'created': false,
  'payroll_run': null,
};

Future<void> _prepareMonth(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('payroll_prepare_month_button'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

/// A payroll backend with no run for this month yet. [draftResponse] is what
/// `draft-monthly/` answers; null makes it fail with a 500.
class _PayrollApi {
  _PayrollApi({required this.draftResponse});

  final Map<String, Object?>? draftResponse;
  final List<Map<String, Object?>> draftBodies = [];
  late final PosApiService service = PosApiService(client: MockClient(_handle));

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/payroll-runs/draft-monthly/')) {
      draftBodies.add(
        Map<String, Object?>.from(jsonDecode(request.body) as Map),
      );
      final body = draftResponse;
      return body == null ? http.Response('', 500) : _json(body);
    }
    if (path.endsWith('/payroll-runs/7/')) {
      return _json(_runJson());
    }
    if (path.endsWith('/payroll-runs/')) {
      return _json({'results': const [], 'next': null});
    }
    if (path.endsWith('/employees/')) {
      return _json({
        'results': [_employeeJson()],
        'next': null,
      });
    }
    if (path.endsWith('/employee-loans/')) {
      return _json({'results': const [], 'next': null});
    }
    if (path.endsWith('/attendance/connection/')) {
      return _json({'base_url': '', 'is_enabled': false});
    }
    return http.Response('', 404);
  }
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Widget _payrollApp(
  EmployeePayrollViewModel viewModel,
  PosApiService apiService,
) {
  final user = PosUser.fromJson(_userJson());
  final capabilities = AuthorizationCapabilities.forUser(user);

  return MaterialApp(
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

Map<String, Object?> _runJson() => {
  'id': 7,
  'run_number': 'PR7',
  'status': 'draft',
  'period_start': '2026-09-01',
  'period_end': '2026-09-30',
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
