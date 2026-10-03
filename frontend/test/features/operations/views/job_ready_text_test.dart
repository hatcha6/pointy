import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/messaging_gateway.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/operations/view_models/job_details_view_model.dart';
import 'package:pointy_frontend/src/features/operations/views/job_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// A job waiting to be collected offers the "ready" text by hand — again
/// after the automatic one, or at all when the shop keeps that off.
const _manager = PosUser(
  id: 1,
  username: 'manager',
  displayName: 'مدير',
  role: UserRole.manager,
  isActive: true,
  smsAvailable: true,
);

OperationsJob _job({bool ready = true, String phone = '0912345678'}) =>
    OperationsJob.fromJson({
      'id': 31,
      'job_number': 'REP-20261002-000031',
      'job_type': 'repair',
      'status': 'open',
      'customer': 5,
      'customer_name': 'مروان',
      'customer_phone': phone,
      'current_stage': 6,
      'current_stage_details': {
        'id': 6,
        'code': ready ? 'ready' : 'testing',
        'name': ready ? 'جاهز للتسليم' : 'قيد الاختبار',
        'display_order': 5,
        'ready_for_pickup': ready,
      },
    });

class _Repo extends OperationsRepository {
  _Repo(this.job) : super(PosApiService());

  final OperationsJob job;
  int readyTexts = 0;

  @override
  Future<Result<OperationsJob>> loadJob(int jobId) async => Ok(job);

  @override
  Future<Result<MessagingSendResult>> notifyJobReady(int jobId) async {
    readyTexts++;
    return const Ok(MessagingSendResult(status: 'queued'));
  }
}

Future<_Repo> _pump(WidgetTester tester, OperationsJob job) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repository = _Repo(job);
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
        capabilities: AuthorizationCapabilities.forUser(_manager),
        currentUser: _manager,
        catalogRepository: CatalogRepository(PosApiService()),
        operationsRepository: repository,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip(l10n.moreActionsTooltip));
    await tester.pumpAndSettle();
  }

  testWidgets('a ready job texts its customer from the menu', (tester) async {
    final repository = await _pump(tester, _job());
    await openMenu(tester);
    await tester.tap(find.text(l10n.jobTextReadyAction));
    await tester.pumpAndSettle();
    expect(repository.readyTexts, 1);
    expect(find.text(l10n.jobTextReadySent), findsOneWidget);
  });

  testWidgets('not ready, or nobody to text: no such entry', (tester) async {
    await _pump(tester, _job(ready: false));
    if (find.byTooltip(l10n.moreActionsTooltip).evaluate().isNotEmpty) {
      await openMenu(tester);
    }
    expect(find.text(l10n.jobTextReadyAction), findsNothing);
  });

  testWidgets('a customer without a phone is not offered a text', (
    tester,
  ) async {
    await _pump(tester, _job(phone: ''));
    if (find.byTooltip(l10n.moreActionsTooltip).evaluate().isNotEmpty) {
      await openMenu(tester);
    }
    expect(find.text(l10n.jobTextReadyAction), findsNothing);
  });
}
