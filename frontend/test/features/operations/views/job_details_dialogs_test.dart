import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/employee_repository.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/operations/view_models/job_details_view_model.dart';
import 'package:pointy_frontend/src/features/operations/views/job_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// The dialogs on this screen that ask for something typed — a cancellation
/// reason, a material's quantity, an invoice's labour and payment — opened and
/// CLOSED the way a technician closes them.
///
/// Cancelling is the half that used to break. Each dialog's controller once
/// lived in the calling method and was disposed the moment `showDialog`
/// returned, which is *before* the dialog's exit animation has finished with
/// its field: the next frame rebuilt a `TextField` against a disposed
/// controller and took the whole screen down with it.
void main() {
  const manager = PosUser(
    id: 1,
    username: 'manager',
    displayName: 'مدير',
    role: UserRole.manager,
    isActive: true,
  );

  const material = ProductVariant(
    id: 77,
    productId: 9,
    sku: 'SCR-1',
    productName: 'شاشة',
    displayName: 'شاشة',
    unitPrice: 120,
  );

  group('the cancellation-reason dialog', () {
    testWidgets('cancelling it leaves the screen standing', (tester) async {
      final repository = _FakeOperationsRepository();
      await _pumpJob(tester, repository: repository, user: manager);
      final l10n = _l10n(tester);

      await _openCancelDialog(tester, l10n);
      expect(find.text(l10n.jobCancelConfirmTitle), findsOneWidget);

      await tester.tap(find.text(l10n.cancelButton));
      await tester.pumpAndSettle();

      // Backing out of the dialog cancels nothing but the dialog.
      expect(repository.cancelledWith, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('confirming carries the typed reason through', (tester) async {
      final repository = _FakeOperationsRepository();
      await _pumpJob(tester, repository: repository, user: manager);
      final l10n = _l10n(tester);

      await _openCancelDialog(tester, l10n);
      await tester.enterText(_dialogField, '  الزبون غيّر رأيه  ');
      await tester.tap(find.text(l10n.jobCancelAction).last);
      await tester.pumpAndSettle();

      expect(repository.cancelledWith, 'الزبون غيّر رأيه');
      expect(tester.takeException(), isNull);
    });

    testWidgets('opening and cancelling it twice is clean', (tester) async {
      await _pumpJob(tester, user: manager);
      final l10n = _l10n(tester);

      for (var i = 0; i < 2; i += 1) {
        await _openCancelDialog(tester, l10n);
        await tester.tap(find.text(l10n.cancelButton));
        await tester.pumpAndSettle();
      }

      expect(tester.takeException(), isNull);
    });
  });

  group('the invoice dialog', () {
    testWidgets('cancelling it leaves the screen standing', (tester) async {
      final repository = _FakeOperationsRepository();
      await _pumpJob(tester, repository: repository, user: manager);
      final l10n = _l10n(tester);

      await _openInvoiceDialog(tester, l10n);
      expect(find.text(l10n.jobInvoiceTitle), findsOneWidget);

      await tester.tap(find.text(l10n.cancelButton));
      await tester.pumpAndSettle();

      // Backing out invoices nothing; the two fields go with the route.
      expect(repository.invoicedDraft, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cancelling after typing in both fields is clean', (
      tester,
    ) async {
      await _pumpJob(tester, user: manager);
      final l10n = _l10n(tester);

      await _openInvoiceDialog(tester, l10n);
      // The amount-now box only exists once the invoice is on credit, so this
      // leaves BOTH controllers with a field rendering against them.
      await tester.enterText(_laborField(l10n), '40');
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      await tester.tap(find.text(l10n.cancelButton));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('confirming carries the labour and the payment through', (
      tester,
    ) async {
      final repository = _FakeOperationsRepository();
      await _pumpJob(tester, repository: repository, user: manager);
      final l10n = _l10n(tester);

      await _openInvoiceDialog(tester, l10n);
      await tester.enterText(_laborField(l10n), '40');
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.jobInvoiceButton).last);
      await tester.pumpAndSettle();

      final draft = repository.invoicedDraft;
      expect(draft, isNotNull);
      expect(draft!.laborTotal, 40);
      expect(draft.onCredit, isFalse);
      // Paid in full, in the method the dialog opens on.
      expect(draft.payments.single.amount, 40);
      expect(draft.payments.single.method, PaymentMethod.cash);
      expect(tester.takeException(), isNull);
    });

    testWidgets('opening and cancelling it twice is clean', (tester) async {
      await _pumpJob(tester, user: manager);
      final l10n = _l10n(tester);

      for (var i = 0; i < 2; i += 1) {
        await _openInvoiceDialog(tester, l10n);
        await tester.tap(find.text(l10n.cancelButton));
        await tester.pumpAndSettle();
      }

      expect(tester.takeException(), isNull);
    });
  });

  group('the material-quantity dialog', () {
    testWidgets('cancelling it leaves the screen standing', (tester) async {
      final repository = _FakeOperationsRepository();
      await _pumpJob(
        tester,
        repository: repository,
        user: manager,
        catalog: _FakeCatalogRepository(material),
      );
      final l10n = _l10n(tester);

      await _openMaterialDialog(tester, material, l10n);
      expect(find.text(material.displayLabel), findsOneWidget);

      await tester.tap(find.text(l10n.cancelButton));
      await tester.pumpAndSettle();

      expect(repository.addedQuantity, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('confirming adds the typed quantity', (tester) async {
      final repository = _FakeOperationsRepository();
      await _pumpJob(
        tester,
        repository: repository,
        user: manager,
        catalog: _FakeCatalogRepository(material),
      );
      final l10n = _l10n(tester);

      await _openMaterialDialog(tester, material, l10n);
      await tester.enterText(_dialogField, '2.5');
      await tester.tap(find.text(l10n.addMaterialButton).last);
      await tester.pumpAndSettle();

      expect(repository.addedQuantity, 2.5);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a quantity of none is refused, not added', (tester) async {
      final repository = _FakeOperationsRepository();
      await _pumpJob(
        tester,
        repository: repository,
        user: manager,
        catalog: _FakeCatalogRepository(material),
      );
      final l10n = _l10n(tester);

      await _openMaterialDialog(tester, material, l10n);
      await tester.enterText(_dialogField, '0');
      await tester.tap(find.text(l10n.addMaterialButton).last);
      await tester.pumpAndSettle();

      // The dialog stays open on a quantity it would only have to drop.
      expect(repository.addedQuantity, isNull);
      expect(find.text(material.displayLabel), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// The field inside whichever dialog is open — the screen behind it has
/// editable fields of its own.
final Finder _dialogField = find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

Future<void> _openCancelDialog(
  WidgetTester tester,
  AppLocalizations l10n,
) async {
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(l10n.jobCancelAction));
  await tester.pumpAndSettle();
}

/// The labour box — the invoice dialog's first field, and the only one there
/// until the invoice goes on credit.
Finder _laborField(AppLocalizations l10n) => find.ancestor(
  of: find.text(l10n.jobLaborTotalLabel),
  matching: find.byType(TextField),
);

Future<void> _openInvoiceDialog(
  WidgetTester tester,
  AppLocalizations l10n,
) async {
  // The button lives in the pinned footer; the dialog's confirm action reuses
  // the same label, so take the trigger before the dialog is on screen.
  await tester.tap(find.text(l10n.jobInvoiceButton).first);
  await tester.pumpAndSettle();
}

Future<void> _openMaterialDialog(
  WidgetTester tester,
  ProductVariant variant,
  AppLocalizations l10n,
) async {
  // The materials section sits below the fold on a test-sized screen.
  final trigger = find.text(l10n.addMaterialButton).first;
  await tester.ensureVisible(trigger);
  await tester.pumpAndSettle();
  await tester.tap(trigger);
  await tester.pumpAndSettle();
  // The picker comes first; choosing a part is what opens the quantity dialog.
  await tester.tap(find.text(variant.displayLabel).last);
  await tester.pumpAndSettle();
}

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(JobDetailsScreen)))!;

OperationsJob _openJob() {
  return OperationsJob.fromJson({
    'id': 12,
    'job_number': 'JOB-12',
    'job_type': 'repair',
    'status': 'open',
    'customer_name': 'زبون',
  });
}

Future<void> _pumpJob(
  WidgetTester tester, {
  required PosUser user,
  _FakeOperationsRepository? repository,
  CatalogRepository? catalog,
}) async {
  final repo = repository ?? _FakeOperationsRepository();
  final viewModel = JobDetailsViewModel(repo, jobId: 12);
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
        catalogRepository: catalog ?? CatalogRepository(PosApiService()),
        operationsRepository: repo,
        employeeRepository: EmployeeRepository(PosApiService()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository() : super(PosApiService());

  String? cancelledWith;
  double? addedQuantity;
  JobInvoiceDraft? invoicedDraft;

  @override
  Future<Result<OperationsJob>> loadJob(int jobId) async => Ok(_openJob());

  @override
  Future<Result<OperationsJob>> cancelJob(
    int jobId, {
    String reason = '',
  }) async {
    cancelledWith = reason;
    return Ok(_openJob());
  }

  @override
  Future<Result<OperationsJob>> invoiceJob(
    int jobId,
    JobInvoiceDraft draft, {
    String? idempotencyKey,
  }) async {
    invoicedDraft = draft;
    return Ok(_openJob());
  }

  @override
  Future<Result<OperationsJob>> addJobMaterial(
    int jobId, {
    required int variant,
    required double quantity,
    required bool consumeNow,
    String? idempotencyKey,
  }) async {
    addedQuantity = quantity;
    return Ok(_openJob());
  }
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository(this.variant) : super(PosApiService());

  final ProductVariant variant;

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async {
    return Ok(ProductVariantPage(variants: [variant], hasMore: false));
  }
}
