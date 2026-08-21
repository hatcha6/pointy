import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bill_of_materials.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/workflow.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/operations/view_models/jobs_board_view_model.dart';
import 'package:pointy_frontend/src/features/operations/view_models/recipes_view_model.dart';
import 'package:pointy_frontend/src/features/operations/views/jobs_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';

const _manager = PosUser(
  id: 1,
  username: 'manager',
  displayName: 'مدير',
  role: UserRole.manager,
  isActive: true,
);

/// The board only offers "new job" when at least one workflow is enabled, so
/// the genuinely-empty case needs a template even though it has no jobs.
final _template = WorkflowTemplate.fromJson(const {
  'id': 1,
  'name': 'تصليح',
  'job_type': 'repair',
  'is_active': true,
  'stages': [
    {'id': 10, 'code': 'intake', 'name': 'استلام', 'display_order': 1},
  ],
});

void main() {
  testWidgets('an untouched empty board still teaches what a job is', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await _pumpBoard(tester);

    // Nothing is filtered, so the onboarding copy and its invitation stand.
    expect(find.text(l10n.jobsEmptyTitle), findsOneWidget);
    expect(find.text(l10n.newJobButton), findsWidgets);
    expect(find.text(l10n.queryClearFiltersButton), findsNothing);
    expect(find.text(l10n.queryNoFilteredResultsTitle), findsNothing);
  });

  testWidgets('a filter that hides every job says so instead of "no jobs yet"', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final viewModel = await _pumpBoard(tester);

    viewModel.assignedToMe = true;
    await tester.pumpAndSettle();

    // The onboarding copy is a lie once a filter is on: the shop may well have
    // a full backlog that the technician simply cannot see.
    expect(find.text(l10n.jobsEmptyTitle), findsNothing);
    expect(find.text(l10n.queryNoFilteredResultsTitle), findsOneWidget);
    expect(find.text(l10n.queryClearFiltersButton), findsOneWidget);
  });

  testWidgets(
    'a search that matches nothing names the term the cashier typed',
    (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      final viewModel = await _pumpBoard(tester);

      viewModel.searchQuery = 'أحمد';
      await tester.pumpAndSettle();

      expect(find.text(l10n.jobsEmptyTitle), findsNothing);
      expect(find.text(l10n.queryNoSearchResultsTitle('أحمد')), findsOneWidget);
      expect(find.text(l10n.queryClearSearchButton), findsOneWidget);
    },
  );

  testWidgets(
    'clearing restores the default board and empties the search box',
    (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      final viewModel = await _pumpBoard(tester);

      await tester.enterText(find.byType(TextField), 'أحمد');
      viewModel.searchQuery = 'أحمد';
      viewModel.statusFilter = OperationsJobStatus.completed;
      viewModel.assignedToMe = true;
      await tester.pumpAndSettle();

      await tester.tap(find.text(l10n.queryClearSearchAndFiltersButton));
      await tester.pumpAndSettle();

      expect(viewModel.searchQuery, isEmpty);
      expect(viewModel.assignedToMe, isFalse);
      expect(viewModel.jobTypeFilter, isNull);
      expect(viewModel.statusFilter, OperationsJobStatus.open);
      expect(viewModel.hasActiveFilters, isFalse);
      // The search box owns its own controller, so the cleared term has to
      // disappear from the field as well as from the query.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
      // Back to the untouched board: the onboarding copy returns.
      expect(find.text(l10n.jobsEmptyTitle), findsOneWidget);
    },
  );
}

Future<JobsBoardViewModel> _pumpBoard(WidgetTester tester) async {
  final repository = _FakeOperationsRepository();
  final viewModel = JobsBoardViewModel(repository);
  final recipesViewModel = RecipesViewModel(repository);
  addTearDown(viewModel.dispose);
  addTearDown(recipesViewModel.dispose);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      home: JobsScreen(
        viewModel: viewModel,
        capabilities: AuthorizationCapabilities.forUser(_manager),
        navigation: FakeAppNavigation(currentUser: _manager),
        currentUser: _manager,
        contactRepository: ContactRepository(PosApiService()),
        operationsRepository: repository,
        catalogRepository: CatalogRepository(PosApiService()),
        recipesViewModel: recipesViewModel,
        onOpenJob: (_) {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  return viewModel;
}

/// Every query comes back empty — the board is blank no matter what the
/// technician filters by, which is exactly the state under test.
class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository() : super(PosApiService());

  @override
  Future<Result<List<WorkflowTemplate>>> loadAllWorkflowTemplates({
    OperationsJobType? jobType,
    bool? isActive,
  }) async {
    return Ok([_template]);
  }

  @override
  Future<Result<List<BillOfMaterials>>> loadAllBoms({bool? isActive}) async {
    return const Ok([]);
  }

  @override
  Future<Result<List<OperationsJob>>> loadAllJobs({
    OperationsJobStatus? status,
    OperationsJobType? jobType,
    int? currentStage,
    int? assignedTo,
    int? customer,
    int? asset,
    int? workflowTemplate,
    String search = '',
  }) async {
    return const Ok([]);
  }
}
