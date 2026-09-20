import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/settings/view_models/integrations_view_model.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/expense_category.dart';
import 'package:pointy_frontend/src/data/models/expense_ledger_entry.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/expense_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/expenses/view_models/expense_categories_view_model.dart';
import 'package:pointy_frontend/src/features/expenses/view_models/expenses_view_model.dart';
import 'package:pointy_frontend/src/features/expenses/views/expenses_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';

/// The expenses ledger (المصروفات) is filtered by five source chips. Deselect
/// the chip a month's only rows belong to and the list goes blank while
/// offering "إضافة مصروف" — an action that provably cannot fix it, because the
/// new expense lands under the very chip that is hidden. The manager taps it,
/// records a real expense, and the screen still says there is nothing here.
void main() {
  testWidgets('a month with no spending keeps its "record one" invitation', (
    tester,
  ) async {
    final viewModel = await _pumpExpenses(tester, entries: const []);

    expect(find.text('لا توجد مصروفات في هذه الفترة.'), findsOneWidget);
    // `FilledButton.icon` builds a private subclass, so `find.byType` — and
    // therefore `widgetWithText` — never matches it; assert on the label.
    expect(find.text('إضافة مصروف'), findsOneWidget);
    // Nothing is hidden, so the filters must not be blamed for an empty month.
    expect(viewModel.isFilteredToNothing, isFalse);
    expect(find.text('لا توجد نتائج مطابقة للفلاتر المحددة'), findsNothing);
  });

  testWidgets('hiding the only source blames the chips and offers them back', (
    tester,
  ) async {
    final viewModel = await _pumpExpenses(
      tester,
      entries: [_entry(ExpenseLedgerSource.expense, 40)],
    );

    await tester.tap(find.widgetWithText(FilterChip, 'مصروف'));
    await tester.pumpAndSettle();

    expect(viewModel.visibleEntries, isEmpty);
    expect(viewModel.isFilteredToNothing, isTrue);
    expect(find.text('لا توجد نتائج مطابقة للفلاتر المحددة'), findsOneWidget);
    expect(find.text('امسح الفلاتر لعرض القائمة كاملة.'), findsOneWidget);
    // "Record an expense" would file the new row behind the hidden chip and
    // leave the list just as blank, so it must not be the offered way out.
    expect(find.text('إضافة مصروف'), findsNothing);
    // This screen has no search box; the shared "clear search" copy would
    // point at a control that is not there.
    expect(find.text('مسح البحث'), findsNothing);
    expect(find.text('مسح البحث والفلاتر'), findsNothing);

    await tester.tap(find.text('مسح الفلاتر'));
    await tester.pumpAndSettle();

    expect(viewModel.isSourceVisible(ExpenseLedgerSource.expense), isTrue);
    expect(viewModel.visibleEntries, hasLength(1));
    expect(find.text('لا توجد نتائج مطابقة للفلاتر المحددة'), findsNothing);
  });
}

Future<ExpensesViewModel> _pumpExpenses(
  WidgetTester tester, {
  required List<ExpenseLedgerEntry> entries,
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final repository = _FakeExpenseRepository()..ledger = _ledgerWith(entries);
  final viewModel = ExpensesViewModel(repository);
  addTearDown(viewModel.dispose);
  final categoriesViewModel = ExpenseCategoriesViewModel(repository);
  addTearDown(categoriesViewModel.dispose);

  final navigation = FakeAppNavigation(currentUser: _manager());
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
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return viewModel;
}

ExpenseLedgerEntry _entry(ExpenseLedgerSource source, double amount) {
  return ExpenseLedgerEntry(
    source: source,
    date: DateTime(2026, 6, 1),
    amount: amount,
    description: 'إيجار المحل',
    category: null,
    paymentMethod: 'cash',
    reference: '',
    relatedId: 7,
  );
}

ExpenseLedger _ledgerWith(List<ExpenseLedgerEntry> entries) {
  return ExpenseLedger(
    start: DateTime(2026, 6, 1),
    end: DateTime(2026, 6, 30),
    entries: entries,
    totalsBySource: const {},
    total: entries.fold(0, (sum, entry) => sum + entry.amount),
    truncated: false,
    totalCount: entries.length,
  );
}

/// Managing expenses is what puts the "record an expense" action on screen.
PosUser _manager() {
  return PosUser.fromJson(const {
    'id': 4,
    'username': 'manager',
    'display_name': 'المدير',
    'email': '',
    'role': 'manager',
    'permissions': ['expenses.view_expense', 'expenses.add_expense'],
    'is_active': true,
  });
}

class _FakeExpenseRepository extends ExpenseRepository {
  _FakeExpenseRepository() : super(PosApiService());

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
}
