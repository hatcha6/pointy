import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/workflow.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/operations/view_models/job_details_view_model.dart';
import 'package:pointy_frontend/src/features/operations/view_models/jobs_board_view_model.dart';
import 'package:pointy_frontend/src/features/operations/views/job_details_screen.dart';
import 'package:pointy_frontend/src/features/operations/views/job_intake_wizard.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// What the counter of a phone-repair shop can do without a manager.
///
/// Field export, 2026-09-25: the cashier could not charge labour — the only
/// way was a catalog service product, the shop had none, and the cashier
/// cannot make products — and the intake's "new customer" blamed the network
/// for what was a missing permission.

/// A cashier holding only what working a job takes — no catalog permission, no
/// materials permission — who must still be able to charge for the work.
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

OperationsJob _job({List<Map<String, Object?>> services = const []}) {
  return OperationsJob.fromJson({
    'id': 9,
    'job_number': 'REP-9',
    'job_type': 'repair',
    'status': 'open',
    'customer_name': 'سالم',
    'services': services,
  });
}

Widget _app(Widget home) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: PointyTheme.light(),
    home: home,
  );
}

void main() {
  group('labour on the job page', () {
    Future<_FakeOperationsRepository> pumpJob(
      WidgetTester tester, {
      OperationsJob? job,
    }) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repository = _FakeOperationsRepository(job ?? _job());
      final viewModel = JobDetailsViewModel(repository, jobId: 9);
      addTearDown(viewModel.dispose);
      await tester.pumpWidget(
        _app(
          JobDetailsScreen(
            viewModel: viewModel,
            capabilities: AuthorizationCapabilities.forUser(_cashier),
            currentUser: _cashier,
            catalogRepository: CatalogRepository(PosApiService()),
            operationsRepository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets('the counter charges labour it describes itself', (
      tester,
    ) async {
      final repository = await pumpJob(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

      await tester.tap(find.text(l10n.jobAddLaborButton));
      await tester.pumpAndSettle();

      // Nothing typed: the dialog says what is missing and adds nothing.
      await tester.tap(find.text(l10n.jobLaborAddConfirm));
      await tester.pumpAndSettle();
      expect(find.text(l10n.jobLaborDescriptionRequired), findsOneWidget);
      expect(find.text(l10n.jobLaborPriceRequired), findsOneWidget);
      expect(repository.addedServices, isEmpty);

      await tester.enterText(
        find.widgetWithText(TextField, l10n.jobLaborDescriptionLabel),
        'تبديل شاشة',
      );
      await tester.enterText(
        find.widgetWithText(TextField, l10n.jobLaborPriceLabel),
        '50',
      );
      await tester.tap(find.text(l10n.jobLaborAddConfirm));
      await tester.pumpAndSettle();

      final draft = repository.addedServices.single;
      expect(draft.variant, isNull);
      expect(draft.note, 'تبديل شاشة');
      expect(draft.unitPrice, 50);
    });

    testWidgets('a labour line is called what the counter wrote', (
      tester,
    ) async {
      await pumpJob(
        tester,
        job: _job(
          services: [
            {
              'id': 1,
              'variant': 77,
              'product_name': 'أجور خدمة وصيانة',
              'variant_name': '',
              'quantity': '1.000',
              'unit_price': '50.00',
              'line_total': '50.00',
              'note': 'تبديل شاشة',
              'is_labor': true,
            },
          ],
        ),
      );

      expect(find.text('تبديل شاشة'), findsOneWidget);
      expect(find.text('أجور خدمة وصيانة'), findsNothing);
    });
  });

  group('taking a device in', () {
    Future<void> pumpIntake(
      WidgetTester tester, {
      required bool canCreateCustomers,
      ContactRepository? contacts,
    }) async {
      final repository = _FakeOperationsRepository(_job());
      final board = JobsBoardViewModel(repository);
      addTearDown(board.dispose);
      await tester.pumpWidget(
        _app(
          JobIntakeWizard(
            template: WorkflowTemplate(
              id: 1,
              name: 'تصليح الأجهزة',
              jobType: OperationsJobType.repair,
              isActive: true,
              isSystem: true,
              jobCount: 0,
              stages: const [],
            ),
            canCreateCustomers: canCreateCustomers,
            boardViewModel: board,
            contactRepository: contacts ?? _FakeContactRepository(),
            operationsRepository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('without the permission, new customers are not offered', (
      tester,
    ) async {
      await pumpIntake(tester, canCreateCustomers: false);
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

      expect(find.text(l10n.intakeNewCustomerButton), findsNothing);
      expect(find.text(l10n.intakeNewCustomerNotAllowed), findsOneWidget);
    });

    testWidgets('a refusal is named as one, not as a dropped connection', (
      tester,
    ) async {
      await pumpIntake(
        tester,
        canCreateCustomers: true,
        contacts: _FakeContactRepository(refuseCreate: true),
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

      await tester.tap(find.text(l10n.intakeNewCustomerButton));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, l10n.intakeCustomerNameLabel),
        'زبون جديد',
      );
      await tester.tap(find.text(l10n.intakeNextButton));
      await tester.pumpAndSettle();

      expect(find.text(l10n.intakeCustomerCreateForbidden), findsOneWidget);
      expect(find.text(l10n.intakeCustomerCreateError), findsNothing);
    });
  });
}

class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository(this.job) : super(PosApiService());

  final OperationsJob job;
  final addedServices = <JobServiceDraft>[];

  @override
  Future<Result<OperationsJob>> loadJob(int jobId) async => Ok(job);

  @override
  Future<Result<OperationsJob>> addJobService(
    int jobId,
    JobServiceDraft draft, {
    String? idempotencyKey,
  }) async {
    addedServices.add(draft);
    return Ok(job);
  }
}

class _FakeContactRepository extends ContactRepository {
  _FakeContactRepository({this.refuseCreate = false}) : super(PosApiService());

  final bool refuseCreate;

  @override
  Future<Result<CustomerPage>> loadCustomers({
    required ContactQuery query,
    int page = 1,
  }) async {
    return const Ok(CustomerPage(customers: [], hasMore: false));
  }

  @override
  Future<Result<Customer>> createCustomer(CustomerDraft draft) async {
    if (!refuseCreate) {
      return const Error(
        PosApiException(message: 'down', statusCode: 503, responseBody: ''),
      );
    }
    return const Error(
      PosApiException(
        message: 'forbidden',
        statusCode: 403,
        responseBody: '{"detail": "You do not have permission."}',
      ),
    );
  }
}
