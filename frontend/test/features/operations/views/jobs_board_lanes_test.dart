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

/// The jobs board of a phone-repair shop, as its counter sees it.
///
/// Field export, 2026-09-25: the board offered a production line and a kitchen
/// beside the repairs, behind a row of chips; a cashier could only move a job
/// one stage at a time; and an empty board read "failed to load jobs".

const _manager = PosUser(
  id: 1,
  username: 'owner',
  role: UserRole.manager,
  isActive: true,
);

const _cashier = PosUser(
  id: 3,
  username: 'counter',
  role: UserRole.cashier,
  isActive: true,
  permissions: {
    'sales.add_order',
    'operations.view_job',
    'operations.add_job',
    'operations.change_job',
  },
);

Map<String, Object?> _stageJson(
  int id,
  String code,
  String name,
  int order, {
  bool approval = false,
  bool handsBack = false,
}) => {
  'id': id,
  'code': code,
  'name': name,
  'display_order': order,
  'is_initial': order == 0,
  'is_terminal': handsBack,
  'requires_customer_approval': approval,
  'requires_settlement': handsBack,
  'releases_custody': handsBack,
};

final _repairStages = [
  _stageJson(1, 'received', 'تم الاستلام', 0),
  _stageJson(2, 'diagnosing', 'قيد التشخيص', 1),
  _stageJson(3, 'waiting_approval', 'بانتظار الموافقة', 2, approval: true),
  _stageJson(4, 'repairing', 'قيد التصليح', 3),
  _stageJson(5, 'delivered', 'تم التسليم', 4, handsBack: true),
];

final _repair = WorkflowTemplate.fromJson({
  'id': 1,
  'name': 'تصليح الأجهزة',
  'job_type': 'repair',
  'is_active': true,
  'is_system': true,
  'stages': _repairStages,
});

final _kitchen = WorkflowTemplate.fromJson({
  'id': 2,
  'name': 'طلب مطبخ',
  'job_type': 'kitchen',
  'is_active': true,
  'is_system': true,
  'stages': [
    _stageJson(21, 'received', 'وصل الطلب', 0),
    _stageJson(22, 'served', 'تم التقديم', 1),
  ],
});

OperationsJob _phone({double? approvedPrice}) => OperationsJob.fromJson({
  'id': 40,
  'job_number': 'REP-40',
  'job_type': 'repair',
  'workflow_template': 1,
  'current_stage': 1,
  'next_stage': _repairStages[1],
  'status': 'open',
  'customer_name': 'سالم',
  'quoted_price': '120.00',
  'approved_price': approvedPrice?.toStringAsFixed(2),
});

void main() {
  testWidgets('a phone shop sees one repair board and no switching chips', (
    tester,
  ) async {
    await _pumpBoard(
      tester,
      templates: [_repair],
      user: _manager,
      jobs: [_phone(approvedPrice: 120)],
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    expect(find.byType(ChoiceChip), findsNothing);
    // The one chip left is "mine" — not a lane, not a kind of work.
    expect(find.byType(FilterChip), findsOneWidget);
    expect(find.text(l10n.jobFilterMine), findsOneWidget);
    expect(find.text(l10n.jobTypeKitchen), findsNothing);
    expect(find.text(l10n.jobTypeProduction), findsNothing);
    // Recipes are a kitchen's and a production line's, not a repair shop's.
    expect(find.byTooltip(l10n.recipesTitle), findsNothing);
    expect(find.text('قيد التشخيص'), findsWidgets);
  });

  testWidgets('a shop with two kinds of work sees both, with nothing hidden', (
    tester,
  ) async {
    await _pumpBoard(
      tester,
      templates: [_kitchen, _repair],
      user: _manager,
      jobs: [_phone(approvedPrice: 120)],
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('طلب مطبخ'), findsOneWidget);
    expect(find.text('تصليح الأجهزة'), findsOneWidget);
    expect(find.byTooltip(l10n.recipesTitle), findsOneWidget);
  });

  testWidgets(
    'a shop that runs no kind of work is told where to switch it on',
    (tester) async {
      await _pumpBoard(tester, templates: const [], user: _manager);
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

      expect(find.text(l10n.jobsNoWorkTypesTitle), findsOneWidget);
      expect(find.text(l10n.jobsLoadError), findsNothing);
    },
  );

  testWidgets('the counter jumps a phone past the stages already done', (
    tester,
  ) async {
    final repository = await _pumpBoard(
      tester,
      templates: [_repair],
      user: _cashier,
      jobs: [_phone(approvedPrice: 120)],
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await tester.tap(find.byTooltip(l10n.jobMoveToStageAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text('قيد التصليح').last);
    await tester.pumpAndSettle();

    expect(repository.movedTo, [4]);
    expect(
      find.text(l10n.jobStageChangedMessage('قيد التصليح')),
      findsOneWidget,
    );
  });

  testWidgets(
    'a jump over the approval stage asks for the agreed price first',
    (tester) async {
      final repository = await _pumpBoard(
        tester,
        templates: [_repair],
        user: _cashier,
        jobs: [_phone()],
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

      await tester.tap(find.byTooltip(l10n.jobMoveToStageAction));
      await tester.pumpAndSettle();
      await tester.tap(find.text('قيد التصليح').last);
      await tester.pumpAndSettle();

      // Nothing moved yet: the customer's price is the question.
      expect(find.text(l10n.jobMoveNeedsApprovalMessage), findsOneWidget);
      expect(repository.movedTo, isEmpty);

      await tester.tap(find.text(l10n.jobApproveConfirm));
      await tester.pumpAndSettle();

      // The quote was filled in, recorded as approved, and then the job moved.
      expect(repository.approvedPrices, ['120.00']);
      expect(repository.movedTo, [4]);
    },
  );

  testWidgets('someone who can only look gets no move buttons', (tester) async {
    const viewer = PosUser(
      id: 5,
      username: 'auditor',
      role: UserRole.cashier,
      isActive: true,
      permissions: {'operations.view_job'},
    );
    await _pumpBoard(
      tester,
      templates: [_repair],
      user: viewer,
      jobs: [_phone(approvedPrice: 120)],
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    expect(find.byTooltip(l10n.jobMoveToStageAction), findsNothing);
    expect(find.text(l10n.jobNextActionButton('قيد التشخيص')), findsNothing);
  });
}

Future<_FakeOperationsRepository> _pumpBoard(
  WidgetTester tester, {
  required List<WorkflowTemplate> templates,
  required PosUser user,
  List<OperationsJob> jobs = const [],
}) async {
  // A workshop screen: the board's columns sit side by side.
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final repository = _FakeOperationsRepository(templates, jobs);
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
        capabilities: AuthorizationCapabilities.forUser(user),
        navigation: FakeAppNavigation(currentUser: user),
        currentUser: user,
        contactRepository: ContactRepository(PosApiService()),
        operationsRepository: repository,
        catalogRepository: CatalogRepository(PosApiService()),
        recipesViewModel: recipesViewModel,
        onOpenJob: (_) {},
        onOpenHistory: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository(this.templates, this.jobs) : super(PosApiService());

  final List<WorkflowTemplate> templates;
  final List<OperationsJob> jobs;
  final movedTo = <int>[];
  final approvedPrices = <Object?>[];

  @override
  Future<Result<List<WorkflowTemplate>>> loadAllWorkflowTemplates({
    OperationsJobType? jobType,
    bool? isActive,
  }) async => Ok(templates);

  /// The recipe list is refused, as it is for a cashier. The board must not
  /// care.
  @override
  Future<Result<List<BillOfMaterials>>> loadAllBoms({bool? isActive}) async {
    return const Error(
      PosApiException(
        message: 'forbidden',
        statusCode: 403,
        responseBody: '{"detail": "no"}',
      ),
    );
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
  }) async => Ok(jobs);

  @override
  Future<Result<List<OperationsJob>>> loadJobsAwaitingHandBack({
    String search = '',
  }) async => const Ok([]);

  @override
  Future<Result<OperationsJob>> updateJob(
    int jobId,
    Map<String, Object?> changes,
  ) async {
    approvedPrices.add(changes['approved_price']);
    return Ok(jobs.first);
  }

  @override
  Future<Result<OperationsJob>> transitionJob(
    int jobId, {
    required int toStage,
    String note = '',
    String handedOverTo = '',
    bool forceRelease = false,
    String? idempotencyKey,
  }) async {
    movedTo.add(toStage);
    return Ok(jobs.first);
  }
}
