// Dev-only preview harness for opening balances and balance adjustments on
// customers', suppliers' and employees' accounts, and a loan's approval.
//
// Renders the real details screens against a fake HTTP backend, so the JSON
// goes through the real parsing. Pick a surface with `?screen=`:
//
//   customer  — a customer holding credit: the balance section with an
//               opening balance, an adjustment, a cash refund and a
//               withdrawn entry, and the refund button.
//   supplier  — a supplier the shop owes, who also owes the shop a little.
//   entry     — the adjustment dialog, open on load.
//   refund    — the customer refund dialog, open on load.
//   create    — the create-customer form with its opening balance on offer.
//   employee  — an employee's account: what they owe and are owed, the
//               entries the next payroll run settles, and both cash actions.
//   loan      — approving a loan, asking where its money comes from.
//
//   make frontend-balances-preview
//
// See AGENTS.md ("UI Preview Harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/balance_entry.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/employee.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/employee_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/contacts/views/balance_entry_dialogs.dart';
import 'package:pointy_frontend/src/features/contacts/views/customer_details_screen.dart';
import 'package:pointy_frontend/src/features/contacts/views/supplier_details_screen.dart';
import 'package:pointy_frontend/src/features/employees/view_models/employee_payroll_view_model.dart';
import 'package:pointy_frontend/src/features/employees/views/employee_account_screen.dart';
import 'package:pointy_frontend/src/features/employees/views/employee_loan_review_actions.dart';
import 'package:pointy_frontend/src/shared/contact_picker_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatefulWidget {
  const _PreviewApp();

  @override
  State<_PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends State<_PreviewApp> {
  late final PosApiService _service = PosApiService(
    baseUrl: 'http://preview.local/api',
    client: MockClient(_handle),
  );
  late final ContactRepository _contacts = ContactRepository(_service);

  final _user = PosUser.fromJson(const {
    'id': 1,
    'username': 'manager',
    'display_name': 'مدير النظام',
    'email': '',
    'role': 'manager',
    'permissions': <String>[],
    'is_active': true,
  });

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    debugPrint('[preview] ${request.method} $path');
    Object? body = const {'count': 0, 'next': null, 'results': <Object?>[]};
    if (path.endsWith('/customers/7/')) {
      body = _customerJson;
    } else if (path.endsWith('/customers/7/sales-summary/')) {
      body = _customerSummaryJson;
    } else if (path.endsWith('/customer-balance-entries/')) {
      body = {'count': 4, 'next': null, 'results': _customerEntries};
    } else if (path.endsWith('/suppliers/12/')) {
      body = _supplierJson;
    } else if (path.endsWith('/supplier-balance-entries/')) {
      body = {'count': 2, 'next': null, 'results': _supplierEntries};
    } else if (path.endsWith('/employees/9/')) {
      body = _employeeJson;
    } else if (path.endsWith('/employees/')) {
      body = {
        'count': 1,
        'next': null,
        'results': [_employeeJson],
      };
    } else if (path.endsWith('/employee-balance-entries/')) {
      body = {'count': 3, 'next': null, 'results': _employeeEntries};
    }
    return http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = AuthorizationCapabilities.forUser(_user);
    final screen = Uri.base.queryParameters['screen'] ?? 'customer';

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
      theme: PointyTheme.light(),
      home: switch (screen) {
        'supplier' => SupplierDetailsScreen(
          supplier: SupplierContact.fromJson(_supplierJson),
          contactRepository: _contacts,
          purchaseRepository: PurchaseRepository(_service),
          printingRepository: PrintingRepository(_service),
          shopSettingsRepository: ShopSettingsRepository(_service),
          capabilities: capabilities,
        ),
        'entry' => _OpenOnLoad(
          open: (context) => showBalanceEntryDialog(
            context,
            party: BalanceParty.customer,
            kind: BalanceEntryKind.adjustment,
            onSubmit: (_) async => null,
          ),
        ),
        'refund' => _OpenOnLoad(
          open: (context) => showBalanceRefundDialog(
            context,
            party: BalanceParty.customer,
            settles: BalanceDirection.weOweThem,
            available: 35,
            onSubmit: (amount, note) async => null,
          ),
        ),
        'create' => _OpenOnLoad(
          open: (context) => showCreateCustomerSheet(
            context: context,
            repository: _contacts,
            allowOpeningBalance: true,
          ),
        ),
        'employee' => EmployeeAccountScreen(
          viewModel: EmployeePayrollViewModel(EmployeeRepository(_service)),
          employee: Employee.fromJson(_employeeJson),
          contactRepository: _contacts,
          capabilities: capabilities,
        ),
        'loan' => _OpenOnLoad(
          open: (context) => showLoanApprovalDialog(
            context,
            loan: EmployeeLoan.fromJson(_loanJson),
            onApprove: (_) async => null,
          ),
        ),
        _ => CustomerDetailsScreen(
          customer: Customer.fromJson(_customerJson),
          contactRepository: _contacts,
          printingRepository: PrintingRepository(_service),
          shopSettingsRepository: ShopSettingsRepository(_service),
          capabilities: capabilities,
        ),
      },
    );
  }
}

/// A plain scaffold that opens a dialog or sheet as soon as it is shown, so
/// the surface can be screenshotted without a click.
class _OpenOnLoad extends StatefulWidget {
  const _OpenOnLoad({required this.open});

  final Future<Object?> Function(BuildContext context) open;

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
  Widget build(BuildContext context) => const Scaffold();
}

const _customerJson = <String, Object?>{
  'id': 7,
  'customer_number': 'C-0007',
  'full_name': 'سالم علي المسماري',
  'phone': '0911111111',
  'email': '',
  'gender': '',
  'marketing_consent': false,
  'notes': '',
  'is_active': true,
};

// Holds 35 of credit: a 90 deposit written as "له علينا", 45 of it spent on a
// later invoice and 10 handed back in cash.
const _customerSummaryJson = <String, Object?>{
  'customer': 7,
  'invoice_count': 6,
  'paid_invoice_count': 6,
  'total_invoiced': '1240.00',
  'net_sales': '1240.00',
  'outstanding_balance': '0.00',
  'credit_balance': '35.00',
  'net_balance': '-35.00',
  'open_debts_total': '0.00',
  'unapplied_credit': '35.00',
  'has_opening_balance': true,
};

const _customerEntries = <Map<String, Object?>>[
  {
    'id': 4,
    'number': 'B20260920000004',
    'kind': 'refund',
    'direction': 'they_owe_us',
    'amount': '10.00',
    'settled_amount': '10.00',
    'remaining_amount': '0.00',
    'effective_date': '2026-09-20',
    'note': 'رد جزء من العربون',
    'created_by_username': 'manager',
    'can_cancel': false,
    'doc_status': 'submitted',
  },
  {
    'id': 3,
    'number': 'B20260612000003',
    'kind': 'adjustment',
    'direction': 'they_owe_us',
    'amount': '30.00',
    'settled_amount': '0.00',
    'remaining_amount': '30.00',
    'effective_date': '2026-06-12',
    'note': 'فرق حساب قديم',
    'created_by_username': 'manager',
    'can_cancel': false,
    'doc_status': 'cancelled',
    'cancel_reason': 'سُجّلت مرتين',
  },
  {
    'id': 2,
    'number': 'B20260301000002',
    'kind': 'adjustment',
    'direction': 'we_owe_them',
    'amount': '90.00',
    'settled_amount': '55.00',
    'remaining_amount': '35.00',
    'effective_date': '2026-03-01',
    'note': 'عربون حجز طقم',
    'created_by_username': 'manager',
    'can_cancel': false,
    'doc_status': 'submitted',
  },
  {
    'id': 1,
    'number': 'B20260101000001',
    'kind': 'opening',
    'direction': 'they_owe_us',
    'amount': '250.00',
    'settled_amount': '250.00',
    'remaining_amount': '0.00',
    'effective_date': '2026-01-01',
    'note': 'من الدفتر القديم',
    'created_by_username': 'manager',
    'can_cancel': false,
    'doc_status': 'submitted',
  },
];

const _supplierJson = <String, Object?>{
  'id': 12,
  'name': 'شركة الحسن للتوريدات',
  'contact_name': 'أحمد',
  'phone': '0922222222',
  'email': '',
  'address': 'بنغازي',
  'notes': '',
  'is_active': true,
  'payable_balance': '800.00',
  'credit_balance': '60.00',
  'net_balance': '740.00',
  'total_bought': '5400.00',
  'purchase_count': 9,
};

const _supplierEntries = <Map<String, Object?>>[
  {
    'id': 6,
    'number': 'B20260710000006',
    'kind': 'adjustment',
    'direction': 'they_owe_us',
    'amount': '60.00',
    'settled_amount': '0.00',
    'remaining_amount': '60.00',
    'effective_date': '2026-07-10',
    'note': 'بضاعة تالفة أُعيدت خارج النظام',
    'created_by_username': 'manager',
    'can_cancel': true,
    'doc_status': 'submitted',
  },
  {
    'id': 5,
    'number': 'B20260101000005',
    'kind': 'opening',
    'direction': 'we_owe_them',
    'amount': '1500.00',
    'settled_amount': '700.00',
    'remaining_amount': '800.00',
    'effective_date': '2026-01-01',
    'note': 'رصيد من الدفتر',
    'created_by_username': 'manager',
    'can_cancel': false,
    'doc_status': 'submitted',
  },
];

const _employeeJson = <String, Object?>{
  'id': 9,
  'employee_number': 'E-0009',
  'full_name': 'مريم الورفلي',
  'job_title': 'كاشير',
  'department': 'المبيعات',
  'status': 'active',
  'employment_type': 'full_time',
  'hire_date': '2025-03-01',
  'active_compensation_plan': {
    'id': 1,
    'employee': 9,
    'pay_type': 'monthly_salary',
    'salary_type': 'monthly_fixed',
    'amount': '1200.00',
    'commission_percent': '0.00',
    'effective_from': '2025-03-01',
    'is_active': true,
  },
  'account_balance': {
    'owed_by_employee': '450.00',
    'owed_to_employee': '75.00',
    'net': '375.00',
    'scheduled_deduction': '150.00',
    'scheduled_payment': '75.00',
    'has_opening_balance': true,
  },
};

const _employeeEntries = <Map<String, Object?>>[
  {
    'id': 23,
    'number': 'B20260905000023',
    'kind': 'adjustment',
    'direction': 'we_owe_them',
    'amount': '75.00',
    'settled_amount': '0.00',
    'remaining_amount': '75.00',
    'scheduled_amount': '75.00',
    'effective_date': '2026-09-05',
    'note': 'مكافأة جرد آخر الشهر',
    'created_by_username': 'manager',
    'can_cancel': true,
    'doc_status': 'submitted',
  },
  {
    'id': 22,
    'number': 'B20260820000022',
    'kind': 'refund',
    'direction': 'we_owe_them',
    'amount': '150.00',
    'settled_amount': '150.00',
    'remaining_amount': '0.00',
    'effective_date': '2026-08-20',
    'note': 'دفعت نقدًا',
    'created_by_username': 'manager',
    'can_cancel': false,
    'doc_status': 'submitted',
  },
  {
    'id': 21,
    'number': 'B20260301000021',
    'kind': 'opening',
    'direction': 'they_owe_us',
    'amount': '900.00',
    'settled_amount': '450.00',
    'remaining_amount': '450.00',
    'scheduled_amount': '150.00',
    'payroll_deduction_limit': '150.00',
    'effective_date': '2026-03-01',
    'note': 'سلفة من الدفتر القديم',
    'created_by_username': 'manager',
    'can_cancel': false,
    'doc_status': 'submitted',
  },
];

const _loanJson = <String, Object?>{
  'id': 4,
  'employee': 9,
  'employee_name': 'مريم الورفلي',
  'status': 'requested',
  'amount': '600.00',
  'monthly_deduction': '200.00',
  'outstanding_balance': '0.00',
  'deducted_amount': '0.00',
  'purpose': 'مصاريف علاج',
};
