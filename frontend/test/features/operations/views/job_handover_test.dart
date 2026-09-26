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

/// The repair counter's last two steps: take the money, then hand the phone
/// back — in that order, and never the other way round.

const _manager = PosUser(
  id: 1,
  username: 'manager',
  displayName: 'مدير',
  role: UserRole.manager,
  isActive: true,
);

const _cashier = PosUser(
  id: 2,
  username: 'cashier',
  displayName: 'كاشير',
  role: UserRole.cashier,
  isActive: true,
  // What the cashier role carries for the repair counter.
  permissions: {'operations.view_job', 'operations.change_job'},
);

OperationsJob _job({
  required String settlementState,
  required String custodyState,
  bool nextStageHandsOver = true,
}) {
  return OperationsJob.fromJson({
    'id': 12,
    'job_number': 'REP-12',
    'job_type': 'repair',
    'status': 'open',
    'customer_name': 'زبون',
    'settlement_state': settlementState,
    'custody_state': custodyState,
    'materials_total': '150.00',
    'next_stage': {
      'id': 7,
      'code': 'delivered',
      'name': 'تم التسليم',
      'display_order': 6,
      'is_terminal': true,
      'requires_settlement': nextStageHandsOver,
      'releases_custody': nextStageHandsOver,
    },
  });
}

class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository(this.job, {this.refuseTransition = false})
    : super(PosApiService());

  final OperationsJob job;
  final bool refuseTransition;
  int transitionCount = 0;
  bool lastForceRelease = false;
  String lastHandedOverTo = '';

  @override
  Future<Result<OperationsJob>> loadJob(int jobId) async => Ok(job);

  @override
  Future<Result<OperationsJob>> transitionJob(
    int jobId, {
    required int toStage,
    String note = '',
    String handedOverTo = '',
    bool forceRelease = false,
    String? idempotencyKey,
  }) async {
    transitionCount++;
    lastForceRelease = forceRelease;
    lastHandedOverTo = handedOverTo;
    if (refuseTransition && !forceRelease) {
      return Error(
        const PosApiException(
          message: 'settlement required',
          statusCode: 400,
          responseBody:
              '{"detail": "settle first", "code": "settlement_required"}',
        ),
      );
    }
    return Ok(job);
  }
}

Future<_FakeOperationsRepository> _pump(
  WidgetTester tester, {
  required OperationsJob job,
  required PosUser user,
  bool refuseTransition = false,
}) async {
  final repository = _FakeOperationsRepository(
    job,
    refuseTransition: refuseTransition,
  );
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
  return repository;
}

void main() {
  testWidgets('a custody-releasing stage is labelled as a handover', (
    tester,
  ) async {
    // "التالي: تم التسليم" reads as one more bureaucratic step. "تسليم للزبون"
    // says what is about to physically happen.
    await _pump(
      tester,
      job: _job(settlementState: 'settled', custodyState: 'with_shop'),
      user: _cashier,
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.jobHandoverButton), findsWidgets);
  });

  testWidgets('a paid job still with the shop says so', (tester) async {
    await _pump(
      tester,
      job: _job(settlementState: 'settled', custodyState: 'with_shop'),
      user: _cashier,
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.jobAwaitingCollectionHint), findsOneWidget);
  });

  testWidgets('handover asks who is collecting before it moves', (
    tester,
  ) async {
    final repository = await _pump(
      tester,
      job: _job(settlementState: 'settled', custodyState: 'with_shop'),
      user: _cashier,
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await tester.tap(find.text(l10n.jobHandoverButton).last);
    await tester.pumpAndSettle();

    expect(find.text(l10n.jobHandoverDialogTitle), findsOneWidget);
    // Nothing has moved yet: the dialog is the confirmation.
    expect(repository.transitionCount, 0);

    await tester.enterText(find.byType(TextField).last, 'أخوه محمد');
    await tester.tap(find.text(l10n.jobHandoverConfirm));
    await tester.pumpAndSettle();

    expect(repository.transitionCount, 1);
    expect(repository.lastHandedOverTo, 'أخوه محمد');
  });

  testWidgets('an unsettled handover is refused, not silently reported', (
    tester,
  ) async {
    final repository = await _pump(
      tester,
      job: _job(settlementState: 'not_invoiced', custodyState: 'with_shop'),
      user: _cashier,
      refuseTransition: true,
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await tester.tap(find.text(l10n.jobHandoverButton).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.jobHandoverConfirm));
    await tester.pumpAndSettle();

    expect(find.text(l10n.jobHandoverBlockedTitle), findsOneWidget);
    expect(find.text(l10n.jobHandoverBlockedMessage), findsOneWidget);
    // A cashier holds no override, so offering one would promise something
    // the backend then refuses.
    expect(find.text(l10n.jobForceReleaseButton), findsNothing);
    expect(repository.lastForceRelease, isFalse);
  });

  testWidgets('a manager is offered the override, and it carries a reason', (
    tester,
  ) async {
    final repository = await _pump(
      tester,
      job: _job(settlementState: 'not_invoiced', custodyState: 'with_shop'),
      user: _manager,
      refuseTransition: true,
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await tester.tap(find.text(l10n.jobHandoverButton).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.jobHandoverConfirm));
    await tester.pumpAndSettle();

    await tester.tap(find.text(l10n.jobForceReleaseButton));
    await tester.pumpAndSettle();

    expect(find.text(l10n.jobForceReleaseDialogTitle), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'زبون قديم');
    await tester.tap(find.text(l10n.jobForceReleaseButton).last);
    await tester.pumpAndSettle();

    expect(repository.lastForceRelease, isTrue);
  });

  testWidgets('an override with no reason never reaches the backend', (
    tester,
  ) async {
    // The backend refuses a blank reason; catching it in the dialog saves the
    // manager watching a request fail for something the form could have said.
    final repository = await _pump(
      tester,
      job: _job(settlementState: 'not_invoiced', custodyState: 'with_shop'),
      user: _manager,
      refuseTransition: true,
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await tester.tap(find.text(l10n.jobHandoverButton).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.jobHandoverConfirm));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.jobForceReleaseButton));
    await tester.pumpAndSettle();

    final before = repository.transitionCount;
    await tester.tap(find.text(l10n.jobForceReleaseButton).last);
    await tester.pumpAndSettle();

    expect(repository.transitionCount, before);
  });
}
