import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/operations/view_models/job_details_view_model.dart';
import 'package:pointy_frontend/src/features/operations/views/job_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// A finished repair at closing time: the cashier has counted and closed
/// their drawer, and the manager is the one taking the money. Field telemetry
/// (2026-09-26 23:37) showed that manager refused an invoice for want of a
/// drawer, then refused the handover for want of an invoice — a job that could
/// not reach its last stage. The app now opens the drawer where the money is.

const _manager = PosUser(
  id: 1,
  username: 'admin',
  displayName: 'مدير',
  role: UserRole.manager,
  isActive: true,
);

Map<String, Object?> _jobJson({
  required bool invoiced,
  bool handedOver = false,
}) {
  return {
    'id': 1,
    'job_number': 'REP-20260925-000001',
    'job_type': 'repair',
    'status': handedOver ? 'completed' : 'open',
    'customer_name': 'زبون',
    'settlement_state': invoiced ? 'settled' : 'not_invoiced',
    'custody_state': handedOver ? 'handed_over' : 'with_shop',
    'materials_total': '0.00',
    'approved_price': '45.00',
    if (invoiced) 'order': 138,
    if (invoiced) 'order_receipt_number': 'R20260926000068',
    if (!handedOver)
      'next_stage': {
        'id': 7,
        'code': 'delivered',
        'name': 'تم التسليم',
        'display_order': 7,
        'is_terminal': true,
        'requires_settlement': true,
        'releases_custody': true,
      },
  };
}

PosApiException _refusal(String code, String detail) {
  return PosApiException(
    message: detail,
    statusCode: 400,
    responseBody: '{"detail": "$detail", "code": "$code"}',
  );
}

/// The server's rules, in miniature: an invoice needs an open drawer, and
/// the handover needs an invoice.
class _Shop {
  bool drawerOpen = false;
  bool invoiced = false;
  bool handedOver = false;
  int invoiceAttempts = 0;
  int transitionAttempts = 0;
  int sessionsStarted = 0;
  double? openingCash;
  String handedOverTo = '';
}

class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository(this.shop) : super(PosApiService());

  final _Shop shop;

  OperationsJob get _job => OperationsJob.fromJson(
    _jobJson(invoiced: shop.invoiced, handedOver: shop.handedOver),
  );

  @override
  Future<Result<OperationsJob>> loadJob(int jobId) async => Ok(_job);

  @override
  Future<Result<OperationsJob>> invoiceJob(
    int jobId,
    JobInvoiceDraft draft, {
    String? idempotencyKey,
  }) async {
    shop.invoiceAttempts++;
    if (!shop.drawerOpen) {
      return Error(
        _refusal(
          'register_session_required',
          'No open register session for this request owner.',
        ),
      );
    }
    shop.invoiced = true;
    return Ok(_job);
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
    shop.transitionAttempts++;
    if (!shop.invoiced && !forceRelease) {
      return Error(
        _refusal(
          'settlement_required',
          "Invoice and settle this job before handing the customer's "
              'property back.',
        ),
      );
    }
    shop.handedOver = true;
    shop.handedOverTo = handedOverTo;
    return Ok(_job);
  }
}

class _FakeRegisterSessionRepository extends RegisterSessionRepository {
  _FakeRegisterSessionRepository(this.shop) : super(PosApiService());

  final _Shop shop;

  @override
  Future<Result<RegisterSession>> startSession({
    required double openingCash,
  }) async {
    shop.sessionsStarted++;
    shop.openingCash = openingCash;
    shop.drawerOpen = true;
    return Ok(
      RegisterSession.fromJson({
        'id': 6,
        'session_number': 'RS-6',
        'status': 'open',
        'opening_cash': openingCash.toStringAsFixed(2),
      }),
    );
  }
}

Future<_Shop> _pump(WidgetTester tester) async {
  final shop = _Shop();
  final repository = _FakeOperationsRepository(shop);
  final viewModel = JobDetailsViewModel(repository, jobId: 1);
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
        registerSessionRepository: _FakeRegisterSessionRepository(shop),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return shop;
}

Future<void> _confirmInvoiceDialog(
  WidgetTester tester,
  AppLocalizations l10n,
) async {
  expect(find.text(l10n.jobInvoiceTitle), findsOneWidget);
  await tester.tap(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, l10n.jobInvoiceButton),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openDrawer(
  WidgetTester tester,
  AppLocalizations l10n, {
  String openingCash = '0',
}) async {
  expect(find.text(l10n.paymentDrawerTitle), findsOneWidget);
  await tester.enterText(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    ),
    openingCash,
  );
  await tester.tap(find.text(l10n.paymentDrawerConfirm));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an invoice refused for want of a drawer opens one and goes '
      'through', (tester) async {
    final shop = await _pump(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await tester.tap(find.text(l10n.jobInvoiceButton).last);
    await tester.pumpAndSettle();
    await _confirmInvoiceDialog(tester, l10n);

    // Refused once, and instead of a generic failure the drawer is offered.
    expect(shop.invoiceAttempts, 1);
    expect(find.text(l10n.operationsActionError), findsNothing);

    await _openDrawer(tester, l10n, openingCash: '20');

    expect(shop.sessionsStarted, 1);
    expect(shop.openingCash, 20);
    // The same invoice, sent again once the drawer is open.
    expect(shop.invoiceAttempts, 2);
    expect(shop.invoiced, isTrue);
    expect(
      find.text(l10n.jobInvoiceSuccess('R20260926000068')),
      findsOneWidget,
    );
  });

  testWidgets('the shop setting that requires an opening count is honoured', (
    tester,
  ) async {
    final shop = await _pump(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await tester.tap(find.text(l10n.jobInvoiceButton).last);
    await tester.pumpAndSettle();
    await _confirmInvoiceDialog(tester, l10n);

    // Without a settings source the stricter POS default applies: a blank
    // opening count is not a zero.
    await tester.tap(find.text(l10n.paymentDrawerConfirm));
    await tester.pumpAndSettle();

    expect(find.text(l10n.openingCashRequiredError), findsOneWidget);
    expect(shop.sessionsStarted, 0);
  });

  testWidgets('cancelling the drawer leaves the job uninvoiced, and says '
      'nothing went wrong', (tester) async {
    final shop = await _pump(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await tester.tap(find.text(l10n.jobInvoiceButton).last);
    await tester.pumpAndSettle();
    await _confirmInvoiceDialog(tester, l10n);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(l10n.cancelButton),
      ),
    );
    await tester.pumpAndSettle();

    expect(shop.sessionsStarted, 0);
    expect(shop.invoiceAttempts, 1);
    expect(shop.invoiced, isFalse);
    expect(find.text(l10n.paymentDrawerTitle), findsNothing);
  });

  testWidgets('a handover blocked for payment finishes once the invoice — and '
      'the drawer it needed — are done', (tester) async {
    final shop = await _pump(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await tester.tap(find.text(l10n.jobHandoverButton).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'صاحب الجهاز');
    await tester.tap(find.text(l10n.jobHandoverConfirm));
    await tester.pumpAndSettle();

    // Refused for payment: invoice it from the question the refusal raises.
    expect(find.text(l10n.jobHandoverBlockedTitle), findsOneWidget);
    await tester.tap(find.text(l10n.jobHandoverBlockedInvoiceAction));
    await tester.pumpAndSettle();
    await _confirmInvoiceDialog(tester, l10n);
    await _openDrawer(tester, l10n);

    expect(shop.invoiced, isTrue);
    // ...and the handover the counter asked for happens without a second tap,
    // to the person they already named.
    expect(shop.transitionAttempts, 2);
    expect(shop.handedOver, isTrue);
    expect(shop.handedOverTo, 'صاحب الجهاز');
    // Its confirmation queues behind the invoice's own.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(
      find.text(l10n.jobStageChangedMessage('تم التسليم')),
      findsOneWidget,
    );
  });
}
