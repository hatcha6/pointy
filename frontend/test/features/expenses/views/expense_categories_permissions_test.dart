import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
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
import '../../../shared/role_fixtures.dart';

/// فئات المصروفات opened for anyone who could record expenses, and offered
/// them adding, renaming and deleting categories — three permissions of their
/// own on the server, which recording expenses does not include.
void main() {
  testWidgets(
    'recording expenses shows the categories and none of the writes',
    (tester) async {
      // An auditor the owner also lets record expenses: no built-in role has
      // the expense writes without the category ones.
      await _openCategories(
        tester,
        userWithRole(UserRole.auditor, {
          ...auditorPermissions,
          'expenses.add_expense',
          'expenses.change_expense',
          'expenses.delete_expense',
          'expenses.view_expensecategory',
        }),
      );

      expect(find.text('إيجار'), findsOneWidget);
      expect(find.byTooltip('إضافة فئة'), findsNothing);
      expect(find.byTooltip('تعديل'), findsNothing);
      expect(find.byTooltip('حذف'), findsNothing);

      // The row is a line to read, not a tap that ends in a refusal.
      await tester.tap(find.text('إيجار'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('a category grant opens the page with only its own action', (
    tester,
  ) async {
    await _openCategories(
      tester,
      userWithRole(UserRole.auditor, {
        ...auditorPermissions,
        'expenses.view_expensecategory',
        'expenses.change_expensecategory',
      }),
    );

    expect(find.byTooltip('تعديل'), findsNWidgets(2));
    expect(find.byTooltip('إضافة فئة'), findsNothing);
    expect(find.byTooltip('حذف'), findsNothing);

    await tester.tap(find.text('إيجار'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('the accountant keeps every category action', (tester) async {
    await _openCategories(
      tester,
      userWithRole(UserRole.accountant, accountantPermissions),
    );

    expect(find.byTooltip('إضافة فئة'), findsOneWidget);
    expect(find.byTooltip('تعديل'), findsNWidgets(2));
    expect(find.byTooltip('حذف'), findsNWidgets(2));
  });

  testWidgets('reading expenses alone does not open the page', (tester) async {
    await _pumpExpenses(
      tester,
      userWithRole(UserRole.auditor, auditorPermissions),
    );

    expect(find.byTooltip('فئات المصروفات'), findsNothing);
  });
}

Future<void> _openCategories(WidgetTester tester, PosUser user) async {
  await _pumpExpenses(tester, user);
  await tester.tap(find.byTooltip('فئات المصروفات'));
  await tester.pumpAndSettle();
}

Future<void> _pumpExpenses(WidgetTester tester, PosUser user) async {
  await tester.binding.setSurfaceSize(const Size(1100, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final repository = _FakeExpenseRepository();
  final viewModel = ExpensesViewModel(repository);
  addTearDown(viewModel.dispose);
  final categoriesViewModel = ExpenseCategoriesViewModel(repository);
  addTearDown(categoriesViewModel.dispose);

  final navigation = FakeAppNavigation(currentUser: user);
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
}

class _FakeExpenseRepository extends ExpenseRepository {
  _FakeExpenseRepository() : super(PosApiService());

  @override
  Future<Result<ExpenseLedger>> loadLedger({
    required DateTime start,
    required DateTime end,
  }) async {
    return Ok(ExpenseLedger.empty(start, end));
  }

  @override
  Future<Result<List<ExpenseCategory>>> loadCategories() async {
    return const Ok([
      ExpenseCategory(id: 1, name: 'إيجار', isActive: true, displayOrder: 0),
      ExpenseCategory(id: 2, name: 'كهرباء', isActive: true, displayOrder: 1),
    ]);
  }
}
