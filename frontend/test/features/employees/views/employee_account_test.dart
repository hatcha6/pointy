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
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/employee_repository.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/attendance/view_models/attendance_view_model.dart';
import 'package:pointy_frontend/src/features/employees/view_models/employee_payroll_view_model.dart';
import 'package:pointy_frontend/src/features/employees/views/employee_payroll_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';

/// An employee's account: opened from their row, stating both sides of it,
/// and settled in cash either way through the user's drawer.
void main() {
  testWidgets('the account opens from the row and states both sides', (
    tester,
  ) async {
    final api = _EmployeeApi();
    await _pumpPayroll(tester, api);

    await tester.tap(find.text('الموظفون'));
    await tester.pumpAndSettle();
    // The row says there is something on the account.
    expect(find.textContaining('على الموظف 300.00'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('employee_row_5')));
    await tester.pumpAndSettle();

    expect(find.text('حساب الموظف'), findsOneWidget);
    expect(find.text('300.00 د.ل'), findsWidgets);
    expect(find.text('40.00 د.ل'), findsWidgets);
    // The entries, with what the next payroll already carries of the debt.
    expect(find.byKey(const ValueKey('balance_entry_11')), findsOneWidget);
    expect(find.textContaining('يُخصم حتى 100.00'), findsOneWidget);
    expect(find.textContaining('مُدرج في مسير رواتب لم يُصرف'), findsOneWidget);
    // Both cash actions, since the account runs both ways.
    expect(
      find.byKey(const ValueKey('balance_pay_out_button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('balance_take_in_button')),
      findsOneWidget,
    );
  });

  testWidgets('taking in what the employee owes says which side it settles', (
    tester,
  ) async {
    final api = _EmployeeApi();
    await _pumpPayroll(tester, api);
    await tester.tap(find.text('الموظفون'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('employee_row_5')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('balance_take_in_button')));
    await tester.pumpAndSettle();
    expect(find.text('تحصيل مبلغ من الموظف'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('balance_refund_amount')),
      '120',
    );
    await tester.tap(find.byKey(const ValueKey('balance_refund_confirm')));
    await tester.pumpAndSettle();

    final body = api.refundBodies.single;
    expect(body['employee'], 5);
    expect(body['amount'], '120.00');
    expect(body['settles'], 'they_owe_us');
    expect(find.text('تم استلام المبلغ من الموظف.'), findsOneWidget);
  });

  testWidgets('a debt the employee owes can be spread over payroll runs', (
    tester,
  ) async {
    final api = _EmployeeApi();
    await _pumpPayroll(tester, api);
    await tester.tap(find.text('الموظفون'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('employee_row_5')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('add_balance_adjustment_button')),
    );
    await tester.pumpAndSettle();
    // "عليه لنا" is the default: the limit is offered.
    expect(find.byKey(const ValueKey('balance_entry_limit')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('balance_entry_amount')),
      '600',
    );
    await tester.enterText(
      find.byKey(const ValueKey('balance_entry_limit')),
      '150',
    );
    await tester.enterText(
      find.byKey(const ValueKey('balance_entry_note')),
      'عجز في الدرج',
    );
    await tester.tap(find.byKey(const ValueKey('balance_entry_save')));
    await tester.pumpAndSettle();

    final body = api.entryBodies.single;
    expect(body['direction'], 'they_owe_us');
    expect(body['payroll_deduction_limit'], '150.00');

    // What the shop owes is paid in full with the next wage: no limit.
    await tester.tap(
      find.byKey(const ValueKey('add_balance_adjustment_button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('له علينا'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('balance_entry_limit')), findsNothing);
  });

  test('a loan paid by transfer names its bank; cash names none', () {
    expect(
      const LoanDisbursement(
        source: LoanDisbursementSource.bank,
        moneyAccountId: 3,
      ).toJson(),
      {
        'disbursement_method': 'transfer',
        'pay_from_register': false,
        'money_account': 3,
      },
    );
    expect(LoanDisbursement.cashBox.toJson(), {
      'disbursement_method': 'cash',
      'pay_from_register': false,
    });
    final loan = EmployeeLoan.fromJson(const {
      'id': 1,
      'employee': 5,
      'status': 'approved',
      'amount': '600.00',
      'monthly_deduction': '200.00',
      'outstanding_balance': '600.00',
      'deducted_amount': '0.00',
      'disbursed_at': '2026-09-20T10:00:00Z',
      'disbursement_method': 'cash',
      'paid_from_register': true,
    });
    expect(loan.disbursedAt, isNotNull);
    expect(loan.paidFromRegister, isTrue);
  });
}

Future<void> _pumpPayroll(WidgetTester tester, _EmployeeApi api) async {
  tester.view.physicalSize = const Size(1200, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final user = PosUser.fromJson(const {
    'id': 1,
    'username': 'manager',
    'display_name': 'مدير',
    'email': '',
    'role': 'manager',
    'permissions': <String>[],
    'is_active': true,
  });
  final capabilities = AuthorizationCapabilities.forUser(user);
  final viewModel = EmployeePayrollViewModel(EmployeeRepository(api.service));
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      theme: PointyTheme.light(),
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
        contactRepository: ContactRepository(api.service),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _EmployeeApi {
  _EmployeeApi() {
    service = PosApiService(
      baseUrl: 'http://test.local/api',
      client: MockClient(_handle),
    );
  }

  late final PosApiService service;
  final List<Map<String, Object?>> refundBodies = [];
  final List<Map<String, Object?>> entryBodies = [];

  static const _employee = <String, Object?>{
    'id': 5,
    'employee_number': 'E-5',
    'full_name': 'سالم',
    'status': 'active',
    'employment_type': 'full_time',
    'hire_date': '2026-01-01',
    'account_balance': {
      'owed_by_employee': '300.00',
      'owed_to_employee': '40.00',
      'net': '260.00',
      'scheduled_deduction': '100.00',
      'scheduled_payment': '40.00',
      'has_opening_balance': true,
    },
  };

  static const _entry = <String, Object?>{
    'id': 11,
    'number': 'B20260501000011',
    'kind': 'opening',
    'direction': 'they_owe_us',
    'amount': '300.00',
    'settled_amount': '0.00',
    'remaining_amount': '300.00',
    'scheduled_amount': '100.00',
    'payroll_deduction_limit': '100.00',
    'effective_date': '2026-05-01',
    'doc_status': 'submitted',
    'can_cancel': false,
  };

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    Object? body = const {'count': 0, 'next': null, 'results': <Object?>[]};
    var status = 200;
    if (path.endsWith('/employees/5/')) {
      body = _employee;
    } else if (path.endsWith('/employees/')) {
      body = {
        'count': 1,
        'next': null,
        'results': [_employee],
      };
    } else if (path.endsWith('/employee-balance-entries/refund/')) {
      refundBodies.add(jsonDecode(request.body) as Map<String, Object?>);
      status = 201;
      body = {
        ..._entry,
        'id': 12,
        'kind': 'refund',
        'direction': 'we_owe_them',
        'amount': '120.00',
      };
    } else if (path.endsWith('/employee-balance-entries/') &&
        request.method == 'POST') {
      entryBodies.add(jsonDecode(request.body) as Map<String, Object?>);
      status = 201;
      body = {..._entry, 'id': 13, 'kind': 'adjustment'};
    } else if (path.endsWith('/employee-balance-entries/')) {
      body = {
        'count': 1,
        'next': null,
        'results': [_entry],
      };
    }
    return http.Response(
      jsonEncode(body),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }
}
