import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/employee_repository.dart';
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
);

OperationsJob _job({required String status}) {
  return OperationsJob.fromJson({
    'id': 12,
    'job_number': 'JOB-12',
    'job_type': 'repair',
    'status': status,
    'customer_name': 'زبون',
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
        employeeRepository: EmployeeRepository(PosApiService()),
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

    expect(find.text(l10n.jobMoveToStageAction), findsOneWidget);
    expect(find.text(l10n.jobCancelAction), findsOneWidget);
  });
}
