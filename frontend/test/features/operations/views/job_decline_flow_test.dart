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
import 'package:pointy_frontend/src/features/operations/views/job_decline_sheet.dart';
import 'package:pointy_frontend/src/features/operations/views/job_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// The customer heard the price. Either they say yes, and the repair goes on,
/// or they say no — and the phone stays on the record until it goes home.

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

Map<String, Object?> _stage(int id, String code, String name, int order) => {
  'id': id,
  'code': code,
  'name': name,
  'display_order': order,
  'requires_customer_approval': code == 'waiting_approval',
};

/// Diagnosed and priced at 250; the customer has not answered.
OperationsJob _awaitingDecision() => OperationsJob.fromJson({
  'id': 21,
  'job_number': 'REP-20260923-000021',
  'job_type': 'repair',
  'status': 'open',
  'customer': 5,
  'customer_name': 'مروان',
  'quoted_price': '250.00',
  'current_stage': 3,
  'current_stage_details': _stage(3, 'waiting_approval', 'بانتظار الموافقة', 2),
  'next_stage': _stage(4, 'repairing', 'قيد التصليح', 3),
});

/// Declined for the price, a 10 LYD fee owed, the phone still here.
OperationsJob _declined({bool feeInvoiced = false}) => OperationsJob.fromJson({
  'id': 22,
  'job_number': 'REP-20260923-000022',
  'job_type': 'repair',
  'status': 'cancelled',
  'customer': 5,
  'customer_name': 'مروان',
  'current_stage': 3,
  'cancel_reason': 'price',
  'cancel_note': 'غالي',
  'cancelled_by_name': 'منى',
  'cancelled_at': '2026-09-23T16:20:00Z',
  'decline_fee': '10.00',
  'is_declined': true,
  'awaiting_hand_back': true,
  if (feeInvoiced) ...{
    'order': 77,
    'order_receipt_number': 'INV-77',
    'settlement_state': 'settled',
  },
});

class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository(this.job, {this.refuseHandBack = false})
    : super(PosApiService());

  OperationsJob job;
  final bool refuseHandBack;
  Map<String, Object?>? lastUpdate;
  int? lastTransitionTo;
  JobDeclineDraft? lastDecline;
  final handBacks = <({String collector, bool force, String note})>[];

  @override
  Future<Result<OperationsJob>> loadJob(int jobId) async => Ok(job);

  @override
  Future<Result<OperationsJob>> updateJob(
    int jobId,
    Map<String, Object?> changes,
  ) async {
    lastUpdate = changes;
    return Ok(job);
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
    lastTransitionTo = toStage;
    return Ok(job);
  }

  @override
  Future<Result<OperationsJob>> declineJob(
    int jobId,
    JobDeclineDraft draft, {
    String? idempotencyKey,
  }) async {
    lastDecline = draft;
    job = _declined();
    return Ok(job);
  }

  @override
  Future<Result<OperationsJob>> handBackJob(
    int jobId, {
    String handedOverTo = '',
    String note = '',
    bool forceRelease = false,
    String? idempotencyKey,
  }) async {
    handBacks.add((collector: handedOverTo, force: forceRelease, note: note));
    if (refuseHandBack && !forceRelease) {
      return Error(
        const PosApiException(
          message: 'settlement required',
          statusCode: 400,
          responseBody:
              '{"detail": "collect the fee", "code": "settlement_required"}',
        ),
      );
    }
    return Ok(job);
  }
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

Future<_FakeOperationsRepository> _pump(
  WidgetTester tester, {
  required OperationsJob job,
  PosUser user = _cashier,
  bool refuseHandBack = false,
}) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repository = _FakeOperationsRepository(
    job,
    refuseHandBack: refuseHandBack,
  );
  final viewModel = JobDetailsViewModel(repository, jobId: job.id);
  addTearDown(viewModel.dispose);
  await tester.pumpWidget(
    _app(
      JobDetailsScreen(
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

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first))!;

/// The text field of the dialog on top — the screen behind it has its own.
Finder _dialogField() => find.descendant(
  of: find.byType(Dialog).last,
  matching: find.byType(TextField),
);

void main() {
  group('at the approval stage', () {
    testWidgets(
      'the footer asks for the customer\'s answer, not the next stage',
      (tester) async {
        await _pump(tester, job: _awaitingDecision());
        final l10n = _l10n(tester);

        expect(find.text(l10n.jobCustomerDecisionTitle), findsOneWidget);
        expect(find.text(l10n.jobApproveButton), findsOneWidget);
        expect(find.text(l10n.jobDeclineButton), findsOneWidget);
        expect(
          find.text(l10n.jobNextActionButton('قيد التصليح')),
          findsNothing,
        );
      },
    );

    testWidgets('approving records the price and moves the job on', (
      tester,
    ) async {
      final repository = await _pump(tester, job: _awaitingDecision());
      final l10n = _l10n(tester);

      await tester.tap(find.text(l10n.jobApproveButton));
      await tester.pumpAndSettle();
      // Starts from the quote: the common answer is "yes, at that price".
      expect(
        tester.widget<TextField>(_dialogField()).controller!.text,
        '250.00',
      );
      await tester.tap(find.text(l10n.jobApproveConfirm));
      await tester.pumpAndSettle();

      expect(repository.lastUpdate, {'approved_price': '250.00'});
      expect(repository.lastTransitionTo, 4);
    });

    testWidgets('declining asks why and what the diagnosis costs', (
      tester,
    ) async {
      final repository = await _pump(tester, job: _awaitingDecision());
      final l10n = _l10n(tester);

      await tester.tap(find.text(l10n.jobDeclineButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.jobDeclineReasonCannotRepair));
      await tester.enterText(
        find.widgetWithText(TextField, l10n.jobDeclineFeeLabel),
        '15',
      );
      await tester.enterText(
        find.widgetWithText(TextField, l10n.jobDeclineNoteLabel),
        'اللوحة الأم تالفة',
      );
      await tester.tap(find.text(l10n.jobDeclineConfirm));
      await tester.pumpAndSettle();

      final draft = repository.lastDecline!;
      expect(draft.reason, JobDeclineReason.cannotRepair);
      expect(draft.fee, 15);
      expect(draft.note, 'اللوحة الأم تالفة');
      expect(find.text(l10n.jobDeclinedMessage), findsOneWidget);
      // The screen now shows the declined job waiting for its owner.
      expect(find.text(l10n.jobDeclinedTitle), findsOneWidget);
    });
  });

  group('a declined job', () {
    testWidgets('says why, what is owed, and that the phone is still here', (
      tester,
    ) async {
      await _pump(tester, job: _declined());
      final l10n = _l10n(tester);

      expect(find.text(l10n.jobDeclinedTitle), findsOneWidget);
      expect(find.text(l10n.jobDeclineReasonPrice), findsWidgets);
      expect(find.textContaining(l10n.jobAwaitingHandBackHint), findsOneWidget);
      expect(find.text(l10n.jobHandBackButton), findsOneWidget);
      expect(find.text(l10n.jobCollectFeeButton), findsOneWidget);
      expect(
        find.text(l10n.jobTimelineDeclined(l10n.jobDeclineReasonPrice)),
        findsOneWidget,
      );
    });

    testWidgets('once the fee is invoiced there is nothing left to collect', (
      tester,
    ) async {
      await _pump(tester, job: _declined(feeInvoiced: true));
      final l10n = _l10n(tester);

      expect(find.text(l10n.jobHandBackButton), findsOneWidget);
      expect(find.text(l10n.jobCollectFeeButton), findsNothing);
    });

    testWidgets('an unpaid fee stops the hand-back and offers to collect it', (
      tester,
    ) async {
      final repository = await _pump(
        tester,
        job: _declined(),
        refuseHandBack: true,
      );
      final l10n = _l10n(tester);

      await tester.tap(find.text(l10n.jobHandBackButton));
      await tester.pumpAndSettle();
      await tester.enterText(_dialogField(), 'أخوه عادل');
      await tester.tap(find.text(l10n.jobHandoverConfirm));
      await tester.pumpAndSettle();

      expect(repository.handBacks.single.collector, 'أخوه عادل');
      expect(find.text(l10n.jobHandBackBlockedTitle), findsOneWidget);
      // A cashier is offered the fee, never the override they do not hold.
      expect(
        find.widgetWithText(FilledButton, l10n.jobCollectFeeButton),
        findsOneWidget,
      );
      expect(find.text(l10n.jobForceReleaseButton), findsNothing);
    });

    testWidgets('a manager can release it unpaid, with a reason', (
      tester,
    ) async {
      final repository = await _pump(
        tester,
        job: _declined(),
        user: _manager,
        refuseHandBack: true,
      );
      final l10n = _l10n(tester);

      await tester.tap(find.text(l10n.jobHandBackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.jobHandoverConfirm));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.jobForceReleaseButton));
      await tester.pumpAndSettle();
      await tester.enterText(_dialogField(), 'زبون دائم');
      await tester.tap(find.text(l10n.jobForceReleaseButton).last);
      await tester.pumpAndSettle();

      expect(repository.handBacks.last.force, isTrue);
      expect(repository.handBacks.last.note, 'زبون دائم');
      expect(find.text(l10n.jobHandedBackMessage), findsOneWidget);
    });
  });

  group('the decline sheet', () {
    Future<void> pumpSheet(WidgetTester tester, {double? suggestedFee}) {
      return tester.pumpWidget(
        _app(Scaffold(body: JobDeclineSheet(suggestedFee: suggestedFee))),
      );
    }

    String feeText(WidgetTester tester, AppLocalizations l10n) {
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, l10n.jobDeclineFeeLabel),
      );
      return field.controller!.text;
    }

    testWidgets('offers the shop\'s fee, except when it cannot be fixed', (
      tester,
    ) async {
      await pumpSheet(tester, suggestedFee: 10);
      final l10n = _l10n(tester);

      expect(feeText(tester, l10n), '10.00');
      await tester.tap(find.text(l10n.jobDeclineReasonCannotRepair));
      await tester.pump();
      expect(feeText(tester, l10n), '');
      await tester.tap(find.text(l10n.jobDeclineReasonNoResponse));
      await tester.pump();
      expect(feeText(tester, l10n), '10.00');
    });

    testWidgets('a fee the cashier typed stays whatever reason they pick', (
      tester,
    ) async {
      await pumpSheet(tester, suggestedFee: 10);
      final l10n = _l10n(tester);

      await tester.enterText(
        find.widgetWithText(TextField, l10n.jobDeclineFeeLabel),
        '5',
      );
      await tester.tap(find.text(l10n.jobDeclineReasonCannotRepair));
      await tester.pump();

      expect(feeText(tester, l10n), '5');
    });
  });

  test('a decline goes over the wire with its reason and fee', () {
    expect(
      const JobDeclineDraft(
        reason: JobDeclineReason.noResponse,
        note: '  لم يرد  ',
        fee: 10,
      ).toJson(),
      {'reason': 'no_response', 'note': 'لم يرد', 'fee': '10.00'},
    );
    expect(
      const JobDeclineDraft(reason: JobDeclineReason.price, fee: 0).toJson(),
      {'reason': 'price', 'fee': null},
    );
  });

  test('a declined job reads back its reason, fee and shelf state', () {
    final job = _declined();

    expect(job.isDeclined, isTrue);
    expect(job.awaitingHandBack, isTrue);
    expect(job.cancelReason, JobDeclineReason.price);
    expect(job.cancelNote, 'غالي');
    expect(job.cancelledByName, 'منى');
    expect(job.declineFee, 10);
    expect(job.owesDeclineFee, isTrue);
    expect(_declined(feeInvoiced: true).owesDeclineFee, isFalse);
  });
}
