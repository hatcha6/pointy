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

/// Recording a float top-up lives here rather than in Shop Settings, because
/// the person who walked to HD Box and paid is an accountant, not the owner.
/// It must therefore be findable: named after the provider, carrying the
/// provider's mark, and collapsing into a menu once a shop sells for more
/// than one — the same control the till uses.
void main() {
  testWidgets('one provider names itself in the app bar', (tester) async {
    await _pumpExpenses(tester, providers: const ['hdbox']);

    expect(find.text('شحن رصيد HD Box'), findsOneWidget);
    // Not a menu: with one provider there is nothing to choose.
    expect(find.text('شحن رصيد'), findsNothing);
  });

  testWidgets('several providers collapse into one menu', (tester) async {
    await _pumpExpenses(tester, providers: const ['hdbox', 'lnet']);

    expect(find.text('شحن رصيد'), findsOneWidget);
    expect(find.text('شحن رصيد HD Box'), findsNothing);

    await tester.tap(find.text('شحن رصيد'));
    await tester.pumpAndSettle();

    // Each float named, so nobody tops up the wrong provider's account.
    expect(find.text('HD Box'), findsOneWidget);
    expect(find.text('LNET'), findsOneWidget);
  });

  testWidgets('a cashier who may not record top-ups sees no action', (
    tester,
  ) async {
    await _pumpExpenses(
      tester,
      providers: const ['hdbox'],
      permissions: const ['expenses.view_expense'],
    );

    expect(find.text('شحن رصيد HD Box'), findsNothing);
    expect(find.byIcon(Icons.account_balance_wallet_outlined), findsNothing);
  });

  testWidgets('no connected provider draws nothing at all', (tester) async {
    // A grocer must not be able to tell this feature shipped.
    await _pumpExpenses(tester, providers: const []);

    expect(find.byIcon(Icons.account_balance_wallet_outlined), findsNothing);
  });
}

Future<void> _pumpExpenses(
  WidgetTester tester, {
  required List<String> providers,
  List<String> permissions = const [
    'expenses.view_expense',
    'integrations.record_integration_topup',
  ],
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final repository = _FakeExpenseRepository();
  final viewModel = ExpensesViewModel(repository);
  addTearDown(viewModel.dispose);
  final categoriesViewModel = ExpenseCategoriesViewModel(repository);
  addTearDown(categoriesViewModel.dispose);
  final integrationsViewModel = IntegrationsViewModel(
    IntegrationsRepository(PosApiService()),
  );
  addTearDown(integrationsViewModel.dispose);

  final navigation = FakeAppNavigation(currentUser: _user(permissions));
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: ExpensesScreen(
          integrationsViewModel: integrationsViewModel,
          integrationProviders: providers,
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

PosUser _user(List<String> permissions) {
  return PosUser.fromJson({
    'id': 9,
    'username': 'accountant',
    'display_name': 'المحاسب',
    'email': '',
    'role': 'accountant',
    'permissions': permissions,
    'is_active': true,
  });
}

class _FakeExpenseRepository extends ExpenseRepository {
  _FakeExpenseRepository() : super(PosApiService());

  @override
  Future<Result<ExpenseLedger>> loadLedger({
    required DateTime start,
    required DateTime end,
  }) async {
    return Ok(
      ExpenseLedger(
        start: start,
        end: end,
        entries: const [],
        totalsBySource: const {},
        total: 0,
        truncated: false,
        totalCount: 0,
      ),
    );
  }

  @override
  Future<Result<List<ExpenseCategory>>> loadCategories() async {
    return Ok(const []);
  }
}
