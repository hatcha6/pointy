import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/expense.dart';
import 'package:pointy_frontend/src/data/models/expense_category.dart';
import 'package:pointy_frontend/src/data/models/expense_ledger_entry.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/expense_repository.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/expenses/view_models/expense_categories_view_model.dart';
import 'package:pointy_frontend/src/features/expenses/view_models/expenses_view_model.dart';
import 'package:pointy_frontend/src/features/expenses/views/expenses_screen.dart';
import 'package:pointy_frontend/src/features/settings/view_models/integrations_view_model.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';

/// An owner reading the expenses list asks of a line they do not recognise
/// who put the money out, when, and from where. Each line now says who and
/// when, and opens what it came from: the drawer shift of a till pay-out, the
/// purchase order of a purchase, the run of a payroll payment.
void main() {
  test('a ledger row reads who recorded it, when, and its shift', () {
    final entry = ExpenseLedgerEntry.fromJson(const {
      'source': 'register_payout',
      'date': '2026-10-06',
      'amount': '15.00',
      'description': 'أكياس',
      'category': null,
      'payment_method': 'cash',
      'reference': '',
      'related_id': 31,
      'recorded_by': 9,
      'recorded_by_name': 'سالم الورفلي',
      'recorded_at': '2026-10-06T12:32:00+00:00',
      'register_session': 12,
      'register_session_number': 'RS-12',
      'document_number': '',
    });

    expect(entry.recordedById, 9);
    expect(entry.recordedByName, 'سالم الورفلي');
    // Read as the moment it was, shown in the till's own time zone.
    expect(
      entry.recordedAt!.isAtSameMomentAs(DateTime.utc(2026, 10, 6, 12, 32)),
      isTrue,
    );
    expect(entry.recordedAt!.isUtc, isFalse);
    expect(entry.registerSessionId, 12);
    expect(entry.registerSessionNumber, 'RS-12');
    // The movement stays the row's id; it is not a purchase or a payroll.
    expect(entry.relatedId, 31);
    expect(entry.purchaseOrderId, isNull);
    expect(entry.payrollRunId, isNull);
  });

  test('a row from an older server still reads, with nobody named', () {
    final entry = ExpenseLedgerEntry.fromJson(const {
      'source': 'purchase',
      'date': '2026-10-06',
      'amount': '200.00',
      'description': 'المورد · PO-7',
      'related_id': 7,
    });

    expect(entry.recordedByName, isEmpty);
    expect(entry.recordedAt, isNull);
    expect(entry.registerSessionId, isNull);
    expect(entry.purchaseOrderId, 7);
  });

  testWidgets('a line names who recorded it and when', (tester) async {
    await _pumpExpenses(
      tester,
      entries: [
        _payout(recordedAt: DateTime(2026, 10, 6, 14, 32)),
        // Entered two days after the day it is dated: the date is named too.
        _expense(recordedAt: DateTime(2026, 10, 8, 9, 5)),
      ],
    );

    expect(find.text('بواسطة سالم — 14:32'), findsOneWidget);
    expect(find.text('بواسطة المدير — 2026/10/08 09:05'), findsOneWidget);
  });

  testWidgets('tapping a till pay-out opens its drawer session', (
    tester,
  ) async {
    final opened = _Opened();
    await _pumpExpenses(tester, entries: [_payout()], opened: opened);

    await tester.tap(find.text('أكياس'));
    await tester.pumpAndSettle();

    expect(opened.sessions, [12]);
  });

  testWidgets('tapping a purchase opens its order; its shift link opens the '
      'drawer that paid for it', (tester) async {
    final opened = _Opened();
    await _pumpExpenses(tester, entries: [_purchase()], opened: opened);

    expect(find.text('أمر الشراء PO-7'), findsOneWidget);
    expect(find.text('جلسة الدرج RS-12'), findsOneWidget);

    await tester.tap(find.text('المورد · PO-7'));
    await tester.pumpAndSettle();
    expect(opened.orders, [7]);
    expect(opened.sessions, isEmpty);

    await tester.tap(find.text('جلسة الدرج RS-12'));
    await tester.pumpAndSettle();
    expect(opened.sessions, [12]);
  });

  testWidgets('tapping a payroll payment opens its run', (tester) async {
    final opened = _Opened();
    await _pumpExpenses(tester, entries: [_payroll()], opened: opened);

    await tester.tap(find.text('مسير الرواتب PR-3'));
    await tester.pumpAndSettle();

    expect(opened.runs, [3]);
  });

  testWidgets('an expense recorded here still edits on tap; its drawer is '
      'the link beside it', (tester) async {
    final opened = _Opened();
    await _pumpExpenses(tester, entries: [_expense()], opened: opened);

    await tester.tap(find.text('جلسة الدرج RS-12'));
    await tester.pumpAndSettle();
    expect(opened.sessions, [12]);

    await tester.tap(find.text('كهرباء'));
    await tester.pumpAndSettle();
    // The row's own tap is the editor, which re-fetches the expense first.
    expect(opened.sessions, [12]);
    expect(_FakeExpenseRepository.loadedExpenses, [44]);
  });

  testWidgets('the recorder opens their profile', (tester) async {
    final opened = _Opened();
    await _pumpExpenses(tester, entries: [_payout()], opened: opened);

    await tester.tap(find.byKey(const ValueKey('expense_recorded_by')));
    await tester.pumpAndSettle();

    expect(opened.recorders, ['9:سالم']);
  });

  testWidgets('without the right to open them, links are plain text', (
    tester,
  ) async {
    await _pumpExpenses(tester, entries: [_payout()]);

    await tester.tap(find.text('جلسة الدرج RS-12'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('أكياس'));
    await tester.pumpAndSettle();

    // Nothing to open and nothing to say: no navigation was offered.
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a record that will not open says so', (tester) async {
    final opened = _Opened(succeed: false);
    await _pumpExpenses(tester, entries: [_purchase()], opened: opened);

    await tester.tap(find.text('المورد · PO-7'));
    await tester.pumpAndSettle();

    expect(opened.orders, [7]);
    expect(
      find.text('تعذر فتح السجل الذي جاء منه هذا المصروف.'),
      findsOneWidget,
    );
  });
}

class _Opened {
  _Opened({this.succeed = true});

  final bool succeed;
  final sessions = <int>[];
  final orders = <int>[];
  final runs = <int>[];
  final recorders = <String>[];
}

ExpenseLedgerEntry _payout({DateTime? recordedAt}) {
  return ExpenseLedgerEntry(
    source: ExpenseLedgerSource.registerPayout,
    date: DateTime(2026, 10, 6),
    amount: 15,
    description: 'أكياس',
    category: null,
    paymentMethod: 'cash',
    reference: '',
    relatedId: 31,
    recordedById: 9,
    recordedByName: 'سالم',
    recordedAt: recordedAt ?? DateTime(2026, 10, 6, 14, 32),
    registerSessionId: 12,
    registerSessionNumber: 'RS-12',
  );
}

ExpenseLedgerEntry _purchase() {
  return ExpenseLedgerEntry(
    source: ExpenseLedgerSource.purchase,
    date: DateTime(2026, 10, 6),
    amount: 200,
    description: 'المورد · PO-7',
    category: null,
    paymentMethod: '',
    reference: '',
    relatedId: 7,
    recordedById: 9,
    recordedByName: 'سالم',
    recordedAt: DateTime(2026, 10, 6, 10),
    registerSessionId: 12,
    registerSessionNumber: 'RS-12',
    documentNumber: 'PO-7',
  );
}

ExpenseLedgerEntry _payroll() {
  return ExpenseLedgerEntry(
    source: ExpenseLedgerSource.payroll,
    date: DateTime(2026, 10, 6),
    amount: 500,
    description: '2026-09-01 → 2026-09-30',
    category: null,
    paymentMethod: '',
    reference: '',
    relatedId: 3,
    recordedById: 4,
    recordedByName: 'المدير',
    documentNumber: 'PR-3',
  );
}

ExpenseLedgerEntry _expense({DateTime? recordedAt}) {
  return ExpenseLedgerEntry(
    source: ExpenseLedgerSource.expense,
    date: DateTime(2026, 10, 6),
    amount: 30,
    description: 'كهرباء',
    category: 'مرافق',
    paymentMethod: 'cash',
    reference: '',
    relatedId: 44,
    recordedById: 4,
    recordedByName: 'المدير',
    recordedAt: recordedAt ?? DateTime(2026, 10, 6, 11),
    registerSessionId: 12,
    registerSessionNumber: 'RS-12',
  );
}

Future<void> _pumpExpenses(
  WidgetTester tester, {
  required List<ExpenseLedgerEntry> entries,
  _Opened? opened,
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  _FakeExpenseRepository.loadedExpenses.clear();

  final repository = _FakeExpenseRepository()..ledger = _ledgerWith(entries);
  final viewModel = ExpensesViewModel(repository);
  addTearDown(viewModel.dispose);
  final categoriesViewModel = ExpenseCategoriesViewModel(repository);
  addTearDown(categoriesViewModel.dispose);

  final navigation = FakeAppNavigation(currentUser: _manager());
  Future<bool> Function(int)? opener(List<int>? into) {
    if (opened == null || into == null) {
      return null;
    }
    return (id) async {
      into.add(id);
      return opened.succeed;
    };
  }

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: ExpensesScreen(
          integrationsViewModel: IntegrationsViewModel(
            IntegrationsRepository(PosApiService()),
          ),
          viewModel: viewModel,
          categoriesViewModel: categoriesViewModel,
          capabilities: navigation.capabilities,
          navigation: navigation,
          onOpenRegisterSession: opener(opened?.sessions),
          onOpenPurchaseOrder: opener(opened?.orders),
          onOpenPayrollRun: opener(opened?.runs),
          onOpenRecorder: opened == null
              ? null
              : (userId, name) async {
                  opened.recorders.add('$userId:$name');
                  return opened.succeed;
                },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ExpenseLedger _ledgerWith(List<ExpenseLedgerEntry> entries) {
  return ExpenseLedger(
    start: DateTime(2026, 10, 1),
    end: DateTime(2026, 10, 31),
    entries: entries,
    totalsBySource: const {},
    total: entries.fold(0, (sum, entry) => sum + entry.amount),
    truncated: false,
    totalCount: entries.length,
  );
}

PosUser _manager() {
  return PosUser.fromJson(const {
    'id': 4,
    'username': 'manager',
    'display_name': 'المدير',
    'email': '',
    'role': 'manager',
    'permissions': [
      'expenses.view_expense',
      'expenses.add_expense',
      'expenses.change_expense',
    ],
    'is_active': true,
  });
}

class _FakeExpenseRepository extends ExpenseRepository {
  _FakeExpenseRepository() : super(PosApiService());

  static final loadedExpenses = <int>[];

  ExpenseLedger? ledger;

  @override
  Future<Result<ExpenseLedger>> loadLedger({
    required DateTime start,
    required DateTime end,
  }) async {
    final value = ledger;
    return value == null ? Error(Exception('no ledger')) : Ok(value);
  }

  @override
  Future<Result<List<ExpenseCategory>>> loadCategories() async {
    return Ok(const [
      ExpenseCategory(id: 1, name: 'إيجار', isActive: true, displayOrder: 0),
    ]);
  }

  @override
  Future<Result<Expense>> loadExpense(int id) async {
    loadedExpenses.add(id);
    return Error(Exception('not in this test'));
  }
}
