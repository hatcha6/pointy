import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/operations/view_models/job_details_view_model.dart';
import 'package:pointy_frontend/src/features/operations/views/job_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

const _manager = PosUser(
  id: 1,
  username: 'manager',
  displayName: 'مدير',
  role: UserRole.manager,
  isActive: true,
);

const _technician = PosUser(
  id: 2,
  username: 'technician',
  displayName: 'فني',
  role: UserRole.cashier,
  isActive: true,
  permissions: {'operations.view_job', 'operations.change_job'},
);

Map<String, Object?> _stage(int id, String code, String name, int order) => {
  'id': id,
  'code': code,
  'name': name,
  'display_order': order,
};

OperationsJob _job({required String status}) {
  return OperationsJob.fromJson({
    'id': 12,
    'job_number': 'JOB-12',
    'job_type': 'repair',
    'status': status,
    'customer_name': 'زبون',
    'current_stage': 2,
    'workflow_stages': [
      _stage(1, 'received', 'تم الاستلام', 0),
      _stage(2, 'diagnosing', 'قيد التشخيص', 1),
      _stage(3, 'repairing', 'قيد التصليح', 2),
      _stage(4, 'ready', 'جاهز للتسليم', 3),
    ],
  });
}

class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository(this.job) : super(PosApiService());

  final OperationsJob job;

  @override
  Future<Result<OperationsJob>> loadJob(int jobId) async => Ok(job);
}

Future<void> _pumpJob(
  WidgetTester tester, {
  required OperationsJob job,
  required PosUser user,
}) async {
  final repository = _FakeOperationsRepository(job);
  final viewModel = JobDetailsViewModel(repository, jobId: job.id);
  addTearDown(viewModel.dispose);

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
      home: JobDetailsScreen(
        viewModel: viewModel,
        capabilities: AuthorizationCapabilities.forUser(user),
        currentUser: user,
        catalogRepository: CatalogRepository(PosApiService()),
        operationsRepository: repository,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a completed job hides the overflow menu when no action is available',
    (tester) async {
      await _pumpJob(
        tester,
        job: _job(status: 'completed'),
        user: _technician,
      );

      // Every entry in this menu is conditional; for a technician on a
      // completed job none of them apply. Rendering the button anyway leaves an
      // enabled control that silently does nothing, because PopupMenuButton
      // skips showing a menu with no items.
      expect(find.text('JOB-12'), findsWidgets);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
    },
  );

  testWidgets('a completed job keeps the menu for someone who can reopen it', (
    tester,
  ) async {
    await _pumpJob(
      tester,
      job: _job(status: 'completed'),
      user: _manager,
    );

    final menu = find.byType(PopupMenuButton<String>);
    expect(menu, findsOneWidget);

    await tester.tap(menu);
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.jobReopenAction), findsOneWidget);
  });

  testWidgets('an open job still shows its stage actions', (tester) async {
    await _pumpJob(
      tester,
      job: _job(status: 'open'),
      user: _technician,
    );

    final menu = find.byType(PopupMenuButton<String>);
    expect(menu, findsOneWidget);

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.byTooltip(l10n.moreActionsTooltip), findsOneWidget);

    await tester.tap(menu);
    await tester.pumpAndSettle();

    expect(find.text(l10n.jobCancelAction), findsOneWidget);
  });

  testWidgets('the counter can put a job on any stage, not just the next', (
    tester,
  ) async {
    // Moving a job past a stage it has already passed in real life used to be
    // a manager's correction, hidden in the overflow menu.
    await _pumpJob(
      tester,
      job: _job(status: 'open'),
      user: _technician,
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    // Where the job is, on the page itself.
    expect(find.text('قيد التشخيص'), findsWidgets);
    await tester.tap(find.text(l10n.jobChangeStageButton));
    await tester.pumpAndSettle();

    // Every stage is offered — behind and ahead — with the current one marked.
    expect(find.text(l10n.jobMoveToStageHint), findsOneWidget);
    for (final name in ['تم الاستلام', 'قيد التصليح', 'جاهز للتسليم']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.text(l10n.jobStageCurrentBadge), findsOneWidget);
  });

  testWidgets('someone who can only look is not offered moves', (tester) async {
    const viewer = PosUser(
      id: 3,
      username: 'auditor',
      displayName: 'مدقق',
      role: UserRole.cashier,
      isActive: true,
      permissions: {'operations.view_job'},
    );
    await _pumpJob(tester, job: _job(status: 'open'), user: viewer);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    expect(find.text(l10n.jobChangeStageButton), findsNothing);
  });
}
