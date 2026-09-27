// Dev-only preview harness for lending an employee money: the new-loan form,
// the loans tab it opens from, and an employee's account with their loans.
//
// Renders the real screens against a fake HTTP backend, so the JSON goes
// through the real parsing. Pick a surface with `?screen=`:
//
//   payroll  — the employees & payroll workspace; open «السلف» for the list
//              and its «سلفة جديدة» button.
//   new      — the new-loan form, open on load, for a manager: the money is
//              handed over in the same step.
//   request  — the same form for someone who may record a loan but not
//              approve one: it waits for approval.
//   account  — an employee's account, with their loans and «سلفة جديدة».
//   picker   — choosing whose loan it is; staff off payroll are greyed out.
//
// Add `&theme=dark` for the dark palette.
//
//   make frontend-employee-loans-preview
//
// test/screens/employee_loans_capture_test.dart renders the same surfaces to
// PNG. See AGENTS.md ("UI Preview Harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/employee.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/attendance_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/employee_repository.dart';
import 'package:pointy_frontend/src/data/repositories/treasury_repository.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/attendance/view_models/attendance_view_model.dart';
import 'package:pointy_frontend/src/features/employees/view_models/employee_payroll_view_model.dart';
import 'package:pointy_frontend/src/features/employees/views/employee_account_screen.dart';
import 'package:pointy_frontend/src/features/employees/views/employee_loan_sheet.dart';
import 'package:pointy_frontend/src/features/employees/views/employee_payroll_screen.dart';
import 'package:pointy_frontend/src/features/employees/views/employee_picker_sheet.dart';
import 'package:pointy_frontend/src/features/treasury/view_models/bank_routing.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  final query = Uri.base.queryParameters;
  runApp(
    EmployeeLoansPreviewApp(
      screen: query['screen'] ?? 'new',
      theme: query['theme'] == 'dark'
          ? PointyTheme.dark()
          : PointyTheme.light(),
    ),
  );
}

/// The preview app on [screen]. Public so the capture test renders exactly
/// what the browser shows, with a [theme] patched for a headless font.
class EmployeeLoansPreviewApp extends StatefulWidget {
  const EmployeeLoansPreviewApp({
    super.key,
    required this.screen,
    required this.theme,
  });

  final String screen;
  final ThemeData theme;

  @override
  State<EmployeeLoansPreviewApp> createState() =>
      _EmployeeLoansPreviewAppState();
}

class _EmployeeLoansPreviewAppState extends State<EmployeeLoansPreviewApp> {
  late final PosApiService _service = PosApiService(
    baseUrl: 'http://preview.local/api',
    client: MockClient(_handle),
  );
  late final BankRouting _bankRouting = BankRouting(
    TreasuryRepository(_service),
  )..load();
  final _railController = PointyNavigationRailController();

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    final query = request.url.queryParameters;
    debugPrint('[preview] ${request.method} $path ${request.url.query}');
    Object? body = const {'count': 0, 'next': null, 'results': <Object?>[]};
    var status = 200;

    if (path.endsWith('/employee-loans/grant/') ||
        (path.endsWith('/employee-loans/') && request.method == 'POST')) {
      // Accepted as sent, so the form's success path can be walked too.
      final sent = jsonDecode(request.body) as Map<String, Object?>;
      final granted = path.endsWith('/grant/');
      status = 201;
      body = {
        ..._loan(
          90,
          employeeId: sent['employee'] as int? ?? 5,
          status: granted ? 'approved' : 'requested',
          amount: '${sent['amount']}',
          monthly: '${sent['monthly_deduction']}',
          outstanding: granted ? '${sent['amount']}' : '0.00',
          createdAt: '2026-09-27T10:00:00Z',
          purpose: '${sent['purpose'] ?? ''}',
        ),
        if (granted) 'disbursed_at': '2026-09-27T10:00:00Z',
        if (granted) 'disbursement_method': sent['disbursement_method'],
        if (granted) 'paid_from_register': sent['pay_from_register'],
      };
    } else if (path.endsWith('/employee-loans/')) {
      final employee = int.tryParse(query['employee'] ?? '');
      final loans = [
        for (final loan in _loans)
          if (employee == null || loan['employee'] == employee) loan,
      ];
      body = {'count': loans.length, 'next': null, 'results': loans};
    } else if (path.endsWith('/employees/5/')) {
      body = _salem;
    } else if (path.endsWith('/employees/')) {
      final search = (query['search'] ?? '').trim();
      final employees = [
        for (final employee in _employees)
          if (search.isEmpty ||
              '${employee['full_name']}'.contains(search) ||
              '${employee['employee_number']}'.contains(search))
            employee,
      ];
      body = {'count': employees.length, 'next': null, 'results': employees};
    } else if (path.endsWith('/money-accounts/')) {
      body = {'count': _accounts.length, 'next': null, 'results': _accounts};
    } else if (path.endsWith('/attendance/connection/')) {
      body = const {'base_url': '', 'is_enabled': false};
    }
    return http.Response(
      jsonEncode(body),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }

  @override
  void dispose() {
    _bankRouting.dispose();
    _railController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Someone who may record a loan but not hand one over: the form sends it
    // for approval instead.
    final user = widget.screen == 'request' ? _recorder : _manager;
    final capabilities = AuthorizationCapabilities.forUser(user);
    final viewModel = EmployeePayrollViewModel(EmployeeRepository(_service));
    final payroll = EmployeePayrollScreen(
      viewModel: viewModel,
      attendanceViewModel: AttendanceViewModel(AttendanceRepository(_service)),
      userRepository: UserRepository(_service),
      capabilities: capabilities,
      navigation: _PreviewNavigation(user, capabilities),
      contactRepository: ContactRepository(_service),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: widget.theme,
      builder: (context, inner) => PointyNavigationRailScope(
        isActive: false,
        controller: _railController,
        child: BankRoutingScope(
          routing: _bankRouting,
          child: inner ?? const SizedBox.shrink(),
        ),
      ),
      home: switch (widget.screen) {
        'payroll' => payroll,
        'account' => EmployeeAccountScreen(
          viewModel: viewModel,
          employee: Employee.fromJson(_salem),
          contactRepository: ContactRepository(_service),
          capabilities: capabilities,
        ),
        'picker' => _OpenOnLoad(
          open: (context) => showEmployeePickerSheet(
            context,
            loadPage: (search, page) =>
                viewModel.searchEmployees(search: search, page: page),
          ),
          child: payroll,
        ),
        _ => _OpenOnLoad(
          open: (context) => showEmployeeLoanSheet(
            context,
            viewModel: viewModel,
            capabilities: capabilities,
          ),
          child: payroll,
        ),
      },
    );
  }
}

/// Shows [child] and opens a sheet over it as soon as it is on screen, so the
/// surface can be screenshotted without a click.
class _OpenOnLoad extends StatefulWidget {
  const _OpenOnLoad({required this.open, required this.child});

  final Future<Object?> Function(BuildContext context) open;
  final Widget child;

  @override
  State<_OpenOnLoad> createState() => _OpenOnLoadState();
}

class _OpenOnLoadState extends State<_OpenOnLoad> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.open(context);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _PreviewNavigation implements AppNavigation {
  const _PreviewNavigation(this.currentUser, this.capabilities);

  @override
  final PosUser currentUser;

  @override
  final AuthorizationCapabilities capabilities;

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}

final _manager = PosUser.fromJson(const {
  'id': 1,
  'username': 'owner',
  'display_name': 'المالك',
  'email': '',
  'role': 'manager',
  'permissions': <String>[],
  'is_active': true,
});

final _recorder = PosUser.fromJson(const {
  'id': 2,
  'username': 'office',
  'display_name': 'موظف المكتب',
  'email': '',
  'role': 'supervisor',
  'permissions': [
    'employees.view_employee',
    'employees.view_employeeloan',
    'employees.add_employeeloan',
    'employees.view_payrollrun',
  ],
  'is_active': true,
});

const _salem = <String, Object?>{
  'id': 5,
  'employee_number': 'E-0005',
  'full_name': 'سالم علي المسماري',
  'job_title': 'كاشير',
  'phone': '0911111111',
  'status': 'active',
  'employment_type': 'full_time',
  'hire_date': '2025-02-01',
  'has_system_access': true,
  'user': 12,
  'user_username': 'salem',
  'active_compensation_plan': {
    'id': 9,
    'employee': 5,
    'pay_type': 'monthly_salary',
    'salary_type': 'monthly_fixed',
    'amount': '1500.00',
    'effective_from': '2026-01-01',
    'is_active': true,
  },
  'account_balance': {
    'owed_by_employee': '0.00',
    'owed_to_employee': '0.00',
    'scheduled_deduction': '0.00',
    'scheduled_payment': '0.00',
    'has_opening_balance': false,
  },
};

const _employees = <Map<String, Object?>>[
  _salem,
  {
    'id': 6,
    'employee_number': 'E-0006',
    'full_name': 'فاطمة الورفلي',
    'job_title': 'محاسبة',
    'status': 'on_leave',
    'employment_type': 'full_time',
    'hire_date': '2024-09-15',
    'active_compensation_plan': {
      'id': 10,
      'employee': 6,
      'pay_type': 'monthly_salary',
      'salary_type': 'monthly_fixed',
      'amount': '1800.00',
      'effective_from': '2026-01-01',
      'is_active': true,
    },
  },
  {
    'id': 7,
    'employee_number': 'E-0007',
    'full_name': 'خالد بن عمران',
    'job_title': 'عامل مخزن',
    'status': 'active',
    'employment_type': 'part_time',
    'hire_date': '2026-03-01',
  },
  {
    'id': 8,
    'employee_number': 'E-0008',
    'full_name': 'مريم التاجوري',
    'job_title': 'مندوبة مبيعات',
    'status': 'terminated',
    'employment_type': 'full_time',
    'hire_date': '2023-05-01',
    'termination_date': '2026-06-30',
  },
];

Map<String, Object?> _loan(
  int id, {
  required int employeeId,
  required String status,
  required String amount,
  required String monthly,
  required String outstanding,
  required String createdAt,
  String purpose = '',
}) {
  final employee = _employees.firstWhere((row) => row['id'] == employeeId);
  return {
    'id': id,
    'employee': employeeId,
    'employee_name': employee['full_name'],
    'employee_number': employee['employee_number'],
    'status': status,
    'amount': amount,
    'monthly_deduction': monthly,
    'outstanding_balance': outstanding,
    'deducted_amount': '0.00',
    'purpose': purpose,
    'requested_by_username': 'owner',
    'created_at': createdAt,
  };
}

final _loans = <Map<String, Object?>>[
  _loan(
    41,
    employeeId: 5,
    status: 'requested',
    amount: '300.00',
    monthly: '100.00',
    outstanding: '0.00',
    createdAt: '2026-09-24T09:00:00Z',
    purpose: 'مصاريف دراسة',
  ),
  {
    ..._loan(
      40,
      employeeId: 5,
      status: 'approved',
      amount: '1200.00',
      monthly: '200.00',
      outstanding: '800.00',
      createdAt: '2026-07-02T09:00:00Z',
      purpose: 'علاج',
    ),
    'disbursed_at': '2026-07-02T09:00:00Z',
    'disbursement_method': 'cash',
  },
  {
    ..._loan(
      38,
      employeeId: 6,
      status: 'approved',
      amount: '2000.00',
      monthly: '250.00',
      outstanding: '1500.00',
      createdAt: '2026-06-10T09:00:00Z',
    ),
    'disbursed_at': '2026-06-10T09:00:00Z',
    'disbursement_method': 'transfer',
    'money_account_name': 'مصرف الجمهورية',
  },
  {
    ..._loan(
      31,
      employeeId: 5,
      status: 'paid',
      amount: '500.00',
      monthly: '250.00',
      outstanding: '0.00',
      createdAt: '2026-02-01T09:00:00Z',
    ),
    'disbursed_at': '2026-02-01T09:00:00Z',
    'disbursement_method': 'cash',
    'paid_from_register': true,
  },
];

const _accounts = <Map<String, Object?>>[
  {
    'id': 1,
    'name': 'الخزينة',
    'kind': 'cash',
    'is_default': true,
    'is_active': true,
  },
  {
    'id': 2,
    'name': 'مصرف الجمهورية',
    'kind': 'bank',
    'bank_name': 'مصرف الجمهورية',
    'bank_slug': 'jbank',
    'account_number': '001-221-4410',
    'is_default': true,
    'is_active': true,
  },
  {
    'id': 3,
    'name': 'مصرف التجارة والتنمية',
    'kind': 'bank',
    'bank_name': 'مصرف التجارة والتنمية',
    'bank_slug': 'tad',
    'account_number': '310-88-1020',
    'is_active': true,
  },
];
