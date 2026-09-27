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
import '../../../shared/role_fixtures.dart';

/// A loan the owner gives: chosen employee, amount, how payroll takes it back
/// and — for someone who may approve loans — the money handed over in the
/// same step. Before this the only way a loan existed was the employee asking
/// for it from their own login.
void main() {
  testWidgets('a manager gives a loan and hands it over in one step', (
    tester,
  ) async {
    final api = _LoanApi();
    await _pumpPayroll(tester, api, user: managerUser);
    await _openNewLoan(tester);

    expect(find.text('سلفة جديدة'), findsWidgets);
    await _pickEmployee(tester, 'سالم');

    // What the manager should weigh before lending more.
    expect(
      find.textContaining('عليه سلفة قائمة، متبقٍ منها 800.00 د.ل'),
      findsOneWidget,
    );
    expect(find.textContaining('يُخصم منها 200.00 د.ل كل شهر'), findsOneWidget);
    expect(
      find.textContaining('طلب سلفة ينتظر القرار: 300.00 د.ل'),
      findsOneWidget,
    );
    expect(find.textContaining('راتب شهري ثابت'), findsWidgets);

    await _type(tester, 'employee_loan_amount', '600');
    await _tap(tester, 'employee_loan_months_3');
    expect(_text(tester, 'employee_loan_monthly'), '200.00');
    expect(
      find.text('تُسدَّد خلال 3 أشهر، 200.00 د.ل كل شهر.'),
      findsOneWidget,
    );
    expect(find.text('3 أقساط'), findsOneWidget);

    await _tap(tester, 'loan_source_drawer');
    expect(find.text('صرف السلفة'), findsOneWidget);
    await _tap(tester, 'employee_loan_submit');

    expect(api.grantBodies.single, {
      'employee': 5,
      'amount': '600.00',
      'monthly_deduction': '200.00',
      'disbursement_method': 'cash',
      'pay_from_register': true,
    });
    expect(api.createBodies, isEmpty);
    expect(find.byKey(const ValueKey('employee_loan_submit')), findsNothing);
    expect(find.text('صُرفت سلفة سالم بمبلغ 600.00 د.ل.'), findsOneWidget);
    // The new loan leads the list, handed over.
    expect(find.byKey(const ValueKey('employee_loan_row_20')), findsOneWidget);
    expect(find.text('صُرفت من الدرج'), findsOneWidget);
  });

  testWidgets('someone who may record but not approve sends it for approval', (
    tester,
  ) async {
    final api = _LoanApi();
    await _pumpPayroll(
      tester,
      api,
      user: userWithRole(UserRole.supervisor, const {
        'employees.view_employee',
        'employees.view_employeeloan',
        'employees.add_employeeloan',
      }),
    );
    await _openNewLoan(tester);

    // Nothing here moves money, and the form says so.
    expect(find.byKey(const ValueKey('employee_loan_hand_over')), findsNothing);
    expect(find.byKey(const ValueKey('loan_source_cashBox')), findsNothing);
    expect(
      find.byKey(const ValueKey('employee_loan_request_only_note')),
      findsOneWidget,
    );
    expect(find.text('تسجيل السلفة'), findsOneWidget);

    await _pickEmployee(tester, 'سالم');
    await _type(tester, 'employee_loan_amount', '300');
    await _type(tester, 'employee_loan_monthly', '100');
    await _type(tester, 'employee_loan_purpose', 'علاج');
    await _tap(tester, 'employee_loan_submit');

    expect(api.grantBodies, isEmpty);
    expect(api.createBodies.single, {
      'employee': 5,
      'amount': '300.00',
      'monthly_deduction': '100.00',
      'purpose': 'علاج',
    });
    expect(find.text('سُجّلت سلفة سالم بانتظار الاعتماد.'), findsOneWidget);
  });

  testWidgets('an approver can still record it for later', (tester) async {
    final api = _LoanApi();
    await _pumpPayroll(tester, api, user: managerUser);
    await _openNewLoan(tester);
    await _pickEmployee(tester, 'سالم');
    await _type(tester, 'employee_loan_amount', '400');
    await _tap(tester, 'employee_loan_months_1');
    expect(find.text('تُخصم كاملة من الراتب القادم.'), findsOneWidget);

    await tester.tap(find.text('سجّلها للاعتماد'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('loan_source_cashBox')), findsNothing);
    expect(
      find.byKey(const ValueKey('employee_loan_later_note')),
      findsOneWidget,
    );
    expect(find.text('تسجيل السلفة'), findsOneWidget);
    await _tap(tester, 'employee_loan_submit');

    expect(api.grantBodies, isEmpty);
    expect(api.createBodies.single['amount'], '400.00');
    expect(api.createBodies.single['monthly_deduction'], '400.00');
  });

  testWidgets('the form says what is missing and sends nothing', (
    tester,
  ) async {
    final api = _LoanApi();
    await _pumpPayroll(tester, api, user: managerUser);
    await _openNewLoan(tester);

    await _tap(tester, 'employee_loan_submit');
    expect(find.text('اختر الموظف الذي تُصرف له السلفة.'), findsOneWidget);
    expect(find.text('أدخل مبلغًا أكبر من صفر.'), findsWidgets);

    await _pickEmployee(tester, 'سالم');
    await _type(tester, 'employee_loan_amount', '100');
    await _type(tester, 'employee_loan_monthly', '150');
    // Said as it is typed, not only on the attempt.
    expect(
      find.text('لا يمكن أن يكون الخصم الشهري أكبر من مبلغ السلفة.'),
      findsOneWidget,
    );
    await _tap(tester, 'employee_loan_submit');

    expect(api.grantBodies, isEmpty);
    expect(api.createBodies, isEmpty);
  });

  testWidgets('staff off payroll are listed but cannot be chosen', (
    tester,
  ) async {
    final api = _LoanApi();
    await _pumpPayroll(tester, api, user: managerUser);
    await _openNewLoan(tester);

    await _tap(tester, 'employee_loan_employee_field');
    expect(find.text('خارج مسير الرواتب'), findsOneWidget);
    await tester.tap(find.text('مريم'));
    await tester.pumpAndSettle();
    // Still choosing: the row did nothing.
    expect(find.byKey(const ValueKey('employee_option_6')), findsOneWidget);
    await tester.tap(find.text('سالم').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('employee_option_6')), findsNothing);
  });

  testWidgets('a spread follows a corrected amount until typed over', (
    tester,
  ) async {
    final api = _LoanApi();
    await _pumpPayroll(tester, api, user: managerUser);
    await _openNewLoan(tester);
    await _pickEmployee(tester, 'سالم');

    await _type(tester, 'employee_loan_amount', '600');
    await _tap(tester, 'employee_loan_months_3');
    await _type(tester, 'employee_loan_amount', '1000');
    expect(_text(tester, 'employee_loan_monthly'), '333.34');
    expect(
      find.text(
        'تُسدَّد خلال 3 أشهر: 333.34 د.ل شهريًا، والقسط الأخير 333.32 د.ل.',
      ),
      findsOneWidget,
    );

    await _type(tester, 'employee_loan_monthly', '250');
    await _type(tester, 'employee_loan_amount', '1100');
    expect(_text(tester, 'employee_loan_monthly'), '250');
    expect(
      find.text(
        'تُسدَّد خلال 5 أشهر: 250.00 د.ل شهريًا، والقسط الأخير 100.00 د.ل.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('an instalment bigger than the salary is flagged, not refused', (
    tester,
  ) async {
    final api = _LoanApi();
    await _pumpPayroll(tester, api, user: managerUser);
    await _openNewLoan(tester);
    await _pickEmployee(tester, 'سالم');

    await _type(tester, 'employee_loan_amount', '3000');
    await _type(tester, 'employee_loan_monthly', '1500');

    expect(
      find.byKey(const ValueKey('employee_loan_above_salary_note')),
      findsOneWidget,
    );
    await _tap(tester, 'employee_loan_submit');
    expect(api.grantBodies, hasLength(1));
  });

  testWidgets('an employee with no pay plan is flagged before lending', (
    tester,
  ) async {
    final api = _LoanApi();
    await _pumpPayroll(tester, api, user: managerUser);
    await _openNewLoan(tester);
    await _pickEmployee(tester, 'خالد');

    expect(
      find.byKey(const ValueKey('employee_loan_no_plan_note')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('employee_loan_open_note')), findsNothing);
  });

  testWidgets(
    'a refused hand-over is said in the form, which keeps its input',
    (tester) async {
      final api = _LoanApi()
        ..grantResponse = http.Response(
          jsonEncode({
            'code': 'register_session_required',
            'detail': 'Cash moves through a drawer.',
          }),
          400,
          headers: _jsonHeaders,
        );
      await _pumpPayroll(tester, api, user: managerUser);
      await _openNewLoan(tester);
      await _pickEmployee(tester, 'سالم');
      await _type(tester, 'employee_loan_amount', '600');
      await _tap(tester, 'employee_loan_months_2');
      await _tap(tester, 'loan_source_drawer');
      await _tap(tester, 'employee_loan_submit');

      expect(api.grantBodies, hasLength(1));
      expect(
        find.text('افتح وردية أولًا، أو اصرف السلفة من الخزينة.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('employee_loan_submit')),
        findsOneWidget,
      );
      expect(_text(tester, 'employee_loan_amount'), '600');
      // Not raised again as the screen's own failure behind the form.
      expect(
        find.text(
          'تعذر حفظ التغيير. راجع البيانات والصلاحيات ثم حاول مرة أخرى.',
        ),
        findsNothing,
      );
    },
  );

  testWidgets('an employee off payroll is refused by name', (tester) async {
    final api = _LoanApi()
      ..grantResponse = http.Response(
        jsonEncode({
          'employee': ['This employee is not on payroll.'],
        }),
        400,
        headers: _jsonHeaders,
      );
    await _pumpPayroll(tester, api, user: managerUser);
    await _openNewLoan(tester);
    await _pickEmployee(tester, 'سالم');
    await _type(tester, 'employee_loan_amount', '600');
    await _tap(tester, 'employee_loan_months_1');
    await _tap(tester, 'employee_loan_submit');

    expect(find.textContaining('هذا الموظف خارج مسير الرواتب'), findsOneWidget);
  });

  testWidgets('from an employee account the loan is already theirs', (
    tester,
  ) async {
    final api = _LoanApi();
    await _pumpPayroll(tester, api, user: managerUser);
    await tester.tap(find.text('الموظفون'));
    await tester.pumpAndSettle();
    await _tap(tester, 'employee_row_5');

    // Their loans are on their account.
    expect(find.byKey(const ValueKey('employee_loan_row_11')), findsOneWidget);
    expect(find.byKey(const ValueKey('employee_loan_row_12')), findsOneWidget);
    final before = api.employeeLoanReads;

    await _tap(tester, 'employee_account_new_loan');
    // Whose it is was decided by where it was opened.
    expect(find.text('تغيير'), findsNothing);
    await _type(tester, 'employee_loan_amount', '500');
    await _tap(tester, 'employee_loan_months_1');
    await _tap(tester, 'employee_loan_submit');

    expect(api.grantBodies.single['employee'], 5);
    expect(api.grantBodies.single['pay_from_register'], false);
    // Read again, so the new loan shows where it was given.
    expect(api.employeeLoanReads, greaterThan(before + 1));
  });

  testWidgets('the form fits a phone', (tester) async {
    final api = _LoanApi();
    await _pumpPayroll(
      tester,
      api,
      user: managerUser,
      size: const Size(390, 844),
    );
    await _openNewLoan(tester);
    await _pickEmployee(tester, 'سالم');
    await _type(tester, 'employee_loan_amount', '600');
    await _tap(tester, 'employee_loan_months_6');

    // No overflow on the way here, and the button is still reachable.
    expect(tester.takeException(), isNull);
    await _tap(tester, 'employee_loan_submit');
    expect(api.grantBodies.single['monthly_deduction'], '100.00');
  });

  group('who may lend', () {
    test('the accountant records loans and hands them over', () {
      final capabilities = capabilitiesFor(
        UserRole.accountant,
        accountantPermissions,
      );
      expect(capabilities.canCreateEmployeeLoans, isTrue);
      expect(capabilities.canApproveEmployeeLoans, isTrue);
    });

    test('recording a loan needs the staff list to say whose', () {
      final capabilities = capabilitiesFor(UserRole.supervisor, const {
        'employees.view_employeeloan',
        'employees.add_employeeloan',
      });
      expect(capabilities.canCreateEmployeeLoans, isFalse);
    });

    test('a cashier does neither', () {
      final capabilities = capabilitiesFor(UserRole.cashier, const {
        'sales.add_order',
      });
      expect(capabilities.canCreateEmployeeLoans, isFalse);
      expect(capabilities.canApproveEmployeeLoans, isFalse);
    });
  });

  group('repayment', () {
    test('equal instalments', () {
      final plan = LoanRepayment.of(600, 200)!;
      expect(plan.months, 3);
      expect(plan.hasSmallerLast, isFalse);
    });

    test('a smaller last instalment', () {
      final plan = LoanRepayment.of(1000, 300)!;
      expect(plan.months, 4);
      expect(plan.lastInstalment, 100);
      expect(plan.hasSmallerLast, isTrue);
    });

    test(
      'a spread rounds its instalment up, never leaving a fraction over',
      () {
        expect(LoanRepayment.instalmentFor(1000, 3), 333.34);
        expect(LoanRepayment.of(1000, 333.34)!.months, 3);
        expect(LoanRepayment.instalmentFor(600, 3), 200);
      },
    );

    test('nothing to say for an instalment above the loan', () {
      expect(LoanRepayment.of(100, 150), isNull);
      expect(LoanRepayment.of(0, 10), isNull);
    });
  });
}

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

String _text(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

/// Types into a field and lets the form rebuild, as a keystroke would.
Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
}

/// Scrolls [key] clear of the pinned footer, then taps it.
Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _openNewLoan(WidgetTester tester) async {
  await tester.tap(find.text('السلف'));
  await tester.pumpAndSettle();
  await _tap(tester, 'new_employee_loan_button');
}

Future<void> _pickEmployee(WidgetTester tester, String name) async {
  await _tap(tester, 'employee_loan_employee_field');
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

Future<void> _pumpPayroll(
  WidgetTester tester,
  _LoanApi api, {
  required PosUser user,
  Size size = const Size(1200, 2000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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

class _LoanApi {
  _LoanApi() {
    service = PosApiService(
      baseUrl: 'http://test.local/api',
      client: MockClient(_handle),
    );
  }

  late final PosApiService service;
  final List<Map<String, Object?>> grantBodies = [];
  final List<Map<String, Object?>> createBodies = [];
  http.Response? grantResponse;
  int employeeLoanReads = 0;

  static const _salem = <String, Object?>{
    'id': 5,
    'employee_number': 'E-5',
    'full_name': 'سالم',
    'job_title': 'كاشير',
    'status': 'active',
    'employment_type': 'full_time',
    'hire_date': '2026-01-01',
    'active_compensation_plan': {
      'id': 9,
      'employee': 5,
      'pay_type': 'monthly_salary',
      'salary_type': 'monthly_fixed',
      'amount': '1000.00',
      'effective_from': '2026-01-01',
      'is_active': true,
    },
  };

  static const _mariam = <String, Object?>{
    'id': 6,
    'employee_number': 'E-6',
    'full_name': 'مريم',
    'status': 'terminated',
    'employment_type': 'full_time',
    'hire_date': '2025-01-01',
  };

  static const _khaled = <String, Object?>{
    'id': 7,
    'employee_number': 'E-7',
    'full_name': 'خالد',
    'status': 'active',
    'employment_type': 'part_time',
    'hire_date': '2026-03-01',
  };

  static const _openLoan = <String, Object?>{
    'id': 11,
    'employee': 5,
    'employee_name': 'سالم',
    'employee_number': 'E-5',
    'status': 'approved',
    'amount': '1200.00',
    'monthly_deduction': '200.00',
    'outstanding_balance': '800.00',
    'deducted_amount': '400.00',
    'created_at': '2026-08-01T10:00:00Z',
    'disbursed_at': '2026-08-01T10:00:00Z',
    'disbursement_method': 'cash',
  };

  static const _pendingLoan = <String, Object?>{
    'id': 12,
    'employee': 5,
    'employee_name': 'سالم',
    'employee_number': 'E-5',
    'status': 'requested',
    'amount': '300.00',
    'monthly_deduction': '100.00',
    'outstanding_balance': '0.00',
    'deducted_amount': '0.00',
    'created_at': '2026-09-20T10:00:00Z',
  };

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    final query = request.url.queryParameters;
    Object? body = const {'count': 0, 'next': null, 'results': <Object?>[]};
    var status = 200;

    if (path.endsWith('/employee-loans/grant/')) {
      final sent = jsonDecode(request.body) as Map<String, Object?>;
      grantBodies.add(sent);
      final refusal = grantResponse;
      if (refusal != null) {
        return refusal;
      }
      status = 201;
      body = _loanFrom(sent, status: 'approved');
    } else if (path.endsWith('/employee-loans/') && request.method == 'POST') {
      final sent = jsonDecode(request.body) as Map<String, Object?>;
      createBodies.add(sent);
      status = 201;
      body = _loanFrom(sent, status: 'requested');
    } else if (path.endsWith('/employee-loans/')) {
      if (query['employee'] == '5') {
        employeeLoanReads++;
      }
      final forOthers = query['employee'] != null && query['employee'] != '5';
      body = {
        'count': forOthers ? 0 : 2,
        'next': null,
        'results': forOthers ? const [] : [_pendingLoan, _openLoan],
      };
    } else if (path.endsWith('/employees/5/')) {
      body = _salem;
    } else if (path.endsWith('/employees/')) {
      body = {
        'count': 3,
        'next': null,
        'results': [_salem, _mariam, _khaled],
      };
    }
    return http.Response(jsonEncode(body), status, headers: _jsonHeaders);
  }

  static Map<String, Object?> _loanFrom(
    Map<String, Object?> sent, {
    required String status,
  }) {
    final handedOver = status == 'approved';
    return {
      'id': 20,
      'employee': sent['employee'],
      'employee_name': 'سالم',
      'employee_number': 'E-5',
      'status': status,
      'amount': sent['amount'],
      'monthly_deduction': sent['monthly_deduction'],
      'outstanding_balance': handedOver ? sent['amount'] : '0.00',
      'deducted_amount': '0.00',
      'purpose': sent['purpose'] ?? '',
      'created_at': '2026-09-27T10:00:00Z',
      if (handedOver) 'disbursed_at': '2026-09-27T10:00:00Z',
      if (handedOver) 'disbursement_method': sent['disbursement_method'],
      if (handedOver) 'paid_from_register': sent['pay_from_register'],
    };
  }
}
