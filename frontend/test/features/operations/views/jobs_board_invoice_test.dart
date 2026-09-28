import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/workflow.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/operations/view_models/jobs_board_view_model.dart';
import 'package:pointy_frontend/src/features/operations/view_models/recipes_view_model.dart';
import 'package:pointy_frontend/src/features/operations/views/jobs_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';

/// Moving a job to its last stage from the board bills it on the way.
///
/// A repair handed back from the board used to be refused as unpaid and sent
/// to the job screen to be invoiced; a kitchen order or a work order moved to
/// its last stage simply left the board unbilled, to be dug out of the
/// history. The invoice and the payment are now asked for on the board, in
/// the move that is due them.

const _cashier = PosUser(
  id: 3,
  username: 'counter',
  role: UserRole.cashier,
  isActive: true,
  permissions: {
    'sales.add_order',
    'sales.add_registersession',
    'operations.view_job',
    'operations.change_job',
  },
);

Map<String, Object?> _stage(
  int id,
  String code,
  String name,
  int order, {
  bool approval = false,
  bool terminal = false,
  bool handsBack = false,
}) => {
  'id': id,
  'code': code,
  'name': name,
  'display_order': order,
  'is_initial': order == 0,
  'is_terminal': terminal,
  'requires_customer_approval': approval,
  'requires_settlement': handsBack,
  'releases_custody': handsBack,
};

const _handover = 'تم التسليم';
const _served = 'تم التقديم';

final _repair = [
  _stage(1, 'received', 'تم الاستلام', 0),
  _stage(2, 'diagnosing', 'قيد التشخيص', 1),
  _stage(3, 'waiting_approval', 'بانتظار الموافقة', 2, approval: true),
  _stage(4, 'ready', 'جاهز للتسليم', 3),
  _stage(5, 'delivered', _handover, 4, terminal: true, handsBack: true),
];

final _kitchen = [
  _stage(21, 'received', 'وصل الطلب', 0),
  _stage(22, 'ready', 'جاهز', 1),
  _stage(23, 'served', _served, 2, terminal: true),
];

final _production = [
  _stage(31, 'planned', 'مخطط', 0),
  _stage(32, 'in_production', 'قيد الإنتاج', 1),
  _stage(33, 'finished', 'اكتمل الإنتاج', 2, terminal: true),
];

const _receipt = 'R20260927000011';

PosApiException _refusal(String code, {Map<String, Object?> extra = const {}}) {
  return PosApiException(
    message: code,
    statusCode: 400,
    responseBody: jsonEncode({'detail': code, 'code': code, ...extra}),
  );
}

/// One job on a server that keeps the rules that matter here: a stage that
/// requires settlement refuses a job with money on it and no invoice, an
/// invoice needs an open drawer and may not pass the agreed price unasked,
/// and paying for work that holds nothing of the customer's finishes it.
class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository({
    required this.jobType,
    required this.stages,
    required this.stageIndex,
    this.approvedPrice,
  }) : super(PosApiService());

  final String jobType;
  final List<Map<String, Object?>> stages;
  int stageIndex;
  double? approvedPrice;
  int? order;
  bool finished = false;
  bool drawerOpen = true;
  int sessionsStarted = 0;
  String handedOverTo = '';

  final calls = <String>[];
  final invoices = <JobInvoiceDraft>[];
  final movedTo = <int>[];

  WorkflowTemplate get template => WorkflowTemplate.fromJson({
    'id': 1,
    'name': 'مسار العمل',
    'job_type': jobType,
    'is_active': true,
    'is_system': true,
    'stages': stages,
  });

  OperationsJob get job => OperationsJob.fromJson({
    'id': 40,
    'job_number': 'JOB-40',
    'job_type': jobType,
    'workflow_template': 1,
    'current_stage': stages[stageIndex]['id'],
    'current_stage_details': stages[stageIndex],
    if (stageIndex + 1 < stages.length) 'next_stage': stages[stageIndex + 1],
    'status': finished ? 'completed' : 'open',
    'customer': 7,
    'customer_name': 'سالم',
    'quoted_price': '120.00',
    'approved_price': approvedPrice?.toStringAsFixed(2),
    'materials_total': '0.00',
    'settlement_state': order == null ? 'not_invoiced' : 'settled',
    'order': order,
    'order_receipt_number': order == null ? '' : _receipt,
  });

  List<WorkflowStage> get _stages => template.stages;

  @override
  Future<Result<List<WorkflowTemplate>>> loadAllWorkflowTemplates({
    OperationsJobType? jobType,
    bool? isActive,
  }) async => Ok([template]);

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
    calls.add('board');
    return Ok([if (!finished) job]);
  }

  @override
  Future<Result<List<OperationsJob>>> loadJobsAwaitingHandBack({
    String search = '',
  }) async => const Ok([]);

  @override
  Future<Result<OperationsJob>> loadJob(int jobId) async {
    calls.add('load');
    return Ok(job);
  }

  @override
  Future<Result<OperationsJob>> updateJob(
    int jobId,
    Map<String, Object?> changes,
  ) async {
    calls.add('approve');
    approvedPrice = double.parse(changes['approved_price']! as String);
    return Ok(job);
  }

  @override
  Future<Result<OperationsJob>> invoiceJob(
    int jobId,
    JobInvoiceDraft draft, {
    String? idempotencyKey,
  }) async {
    calls.add('invoice');
    invoices.add(draft);
    if (!drawerOpen) {
      return Error(_refusal('register_session_required'));
    }
    final agreed = approvedPrice;
    if (agreed != null &&
        draft.laborTotal > agreed &&
        !draft.acknowledgeOverQuote) {
      return Error(
        _refusal(
          'over_approved_price',
          extra: {
            'approved_price': agreed.toStringAsFixed(2),
            'invoice_total': draft.laborTotal.toStringAsFixed(2),
          },
        ),
      );
    }
    order = 138;
    if (!_stages.any((stage) => stage.releasesCustody)) {
      stageIndex = _stages.indexWhere((stage) => stage.isTerminal);
      finished = true;
    }
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
    calls.add('move');
    movedTo.add(toStage);
    final target = _stages.indexWhere((stage) => stage.id == toStage);
    final entered = _stages.sublist(stageIndex + 1, target + 1);
    if (entered.any((stage) => stage.requiresSettlement) &&
        order == null &&
        (approvedPrice ?? 0) > 0) {
      return Error(_refusal('settlement_required'));
    }
    stageIndex = target;
    finished = _stages[target].isTerminal;
    this.handedOverTo = handedOverTo;
    return Ok(job);
  }
}

class _FakeRegisterSessionRepository extends RegisterSessionRepository {
  _FakeRegisterSessionRepository(this.server) : super(PosApiService());

  final _FakeOperationsRepository server;

  @override
  Future<Result<RegisterSession>> startSession({
    required double openingCash,
  }) async {
    server.sessionsStarted++;
    server.drawerOpen = true;
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

Future<_FakeOperationsRepository> _pumpBoard(
  WidgetTester tester,
  _FakeOperationsRepository server,
) async {
  // A workshop screen: every column side by side, none scrolled away.
  tester.view.physicalSize = const Size(2000, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final viewModel = JobsBoardViewModel(server);
  final recipesViewModel = RecipesViewModel(server);
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
        capabilities: AuthorizationCapabilities.forUser(_cashier),
        navigation: FakeAppNavigation(currentUser: _cashier),
        currentUser: _cashier,
        contactRepository: ContactRepository(PosApiService()),
        operationsRepository: server,
        catalogRepository: CatalogRepository(PosApiService()),
        registerSessionRepository: _FakeRegisterSessionRepository(server),
        recipesViewModel: recipesViewModel,
        onOpenJob: (_) {},
        onOpenHistory: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  server.calls.clear();
  return server;
}

/// A phone that is fixed and waiting for its owner.
_FakeOperationsRepository _readyPhone({double? approvedPrice = 120}) =>
    _FakeOperationsRepository(
      jobType: 'repair',
      stages: _repair,
      stageIndex: 3,
      approvedPrice: approvedPrice,
    );

Finder _inDialog(Finder matching) =>
    find.descendant(of: find.byType(AlertDialog), matching: matching);

Future<void> _tapInDialog(WidgetTester tester, String label) async {
  await tester.tap(_inDialog(find.text(label)));
  await tester.pumpAndSettle();
}

Future<void> _handOverTo(
  WidgetTester tester,
  AppLocalizations l10n,
  String collector,
) async {
  expect(find.text(l10n.jobHandoverDialogTitle), findsOneWidget);
  await tester.enterText(_inDialog(find.byType(TextField)), collector);
  await _tapInDialog(tester, l10n.jobHandoverConfirm);
}

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  testWidgets('handing a repair back takes the money on the board first', (
    tester,
  ) async {
    final server = await _pumpBoard(tester, _readyPhone());

    await tester.tap(
      find.text(l10n.jobNextActionButton(l10n.jobHandoverButton)),
    );
    await tester.pumpAndSettle();

    // The invoice, here on the board, on the job as it stands now.
    expect(find.text(l10n.jobInvoiceTitle), findsOneWidget);
    expect(find.text(l10n.jobFinishInvoiceLead(_handover)), findsOneWidget);
    // A phone does not leave unpaid: there is no going on without paying.
    expect(find.text(l10n.jobFinishWithoutInvoiceAction), findsNothing);
    expect(server.calls, ['load']);

    await _tapInDialog(tester, l10n.jobInvoiceButton);

    final invoice = server.invoices.single;
    expect(invoice.laborTotal, 120);
    expect(invoice.onCredit, isFalse);
    expect(invoice.payments.single.method, PaymentMethod.cash);
    expect(invoice.payments.single.amount, 120);
    expect(find.text(l10n.jobInvoiceSuccess(_receipt)), findsOneWidget);

    // Paid — then the handover's own question, and the phone goes home.
    await _handOverTo(tester, l10n, 'صاحب الجهاز');

    expect(server.movedTo, [5]);
    expect(server.handedOverTo, 'صاحب الجهاز');
    expect(server.calls, ['load', 'invoice', 'move', 'board']);
    expect(find.text(l10n.jobHandoverBlockedTitle), findsNothing);
    expect(find.text(l10n.operationsActionError), findsNothing);
  });

  testWidgets('backing out of the invoice leaves the job where it was', (
    tester,
  ) async {
    final server = await _pumpBoard(tester, _readyPhone());

    await tester.tap(
      find.text(l10n.jobNextActionButton(l10n.jobHandoverButton)),
    );
    await tester.pumpAndSettle();
    await _tapInDialog(tester, l10n.cancelButton);

    expect(server.invoices, isEmpty);
    expect(server.movedTo, isEmpty);
    expect(find.text(l10n.jobHandoverDialogTitle), findsNothing);
    expect(find.text(l10n.operationsActionError), findsNothing);
  });

  testWidgets('a free repair goes home without an invoice', (tester) async {
    final server = await _pumpBoard(tester, _readyPhone(approvedPrice: 0));

    await tester.tap(
      find.text(l10n.jobNextActionButton(l10n.jobHandoverButton)),
    );
    await tester.pumpAndSettle();

    // Nothing on it to pay for, so the server lets it through unbilled — and
    // the dialog says so rather than demanding an invoice of nothing.
    await _tapInDialog(tester, l10n.jobFinishWithoutInvoiceAction);
    await _handOverTo(tester, l10n, 'سالم');

    expect(server.invoices, isEmpty);
    expect(server.movedTo, [5]);
    expect(server.handedOverTo, 'سالم');
  });

  testWidgets('a jump to the handover asks the price, then the money, then '
      'who takes it', (tester) async {
    final server = await _pumpBoard(
      tester,
      _FakeOperationsRepository(
        jobType: 'repair',
        stages: _repair,
        stageIndex: 1,
      ),
    );

    await tester.tap(find.byTooltip(l10n.jobMoveToStageAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_handover).last);
    await tester.pumpAndSettle();

    expect(find.text(l10n.jobMoveNeedsApprovalMessage), findsOneWidget);
    await _tapInDialog(tester, l10n.jobApproveConfirm);

    // The invoice bills the price just agreed — read back from the server,
    // not from the card, which never saw it.
    expect(find.text(l10n.jobInvoiceTitle), findsOneWidget);
    await _tapInDialog(tester, l10n.jobInvoiceButton);
    expect(server.invoices.single.laborTotal, 120);

    await _handOverTo(tester, l10n, 'سالم');

    expect(server.calls, ['approve', 'load', 'invoice', 'move', 'board']);
    expect(server.movedTo, [5]);
  });

  testWidgets('a kitchen order is finished by being paid for', (tester) async {
    final server = await _pumpBoard(
      tester,
      _FakeOperationsRepository(
        jobType: 'kitchen',
        stages: _kitchen,
        stageIndex: 1,
        approvedPrice: 35,
      ),
    );

    await tester.tap(find.text(l10n.jobNextActionButton(_served)));
    await tester.pumpAndSettle();

    expect(find.text(l10n.jobFinishInvoiceLead(_served)), findsOneWidget);
    await _tapInDialog(tester, l10n.jobInvoiceButton);

    // Paying ended it on the server: no move is left to send, and the board
    // lets it go.
    expect(server.invoices.single.laborTotal, 35);
    expect(server.movedTo, isEmpty);
    expect(server.calls, ['load', 'invoice', 'board']);
    expect(find.text('JOB-40'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.text(l10n.jobStageChangedMessage(_served)), findsOneWidget);
  });

  testWidgets('a kitchen order can still be finished unbilled', (tester) async {
    final server = await _pumpBoard(
      tester,
      _FakeOperationsRepository(
        jobType: 'kitchen',
        stages: _kitchen,
        stageIndex: 1,
        approvedPrice: 35,
      ),
    );

    await tester.tap(find.text(l10n.jobNextActionButton(_served)));
    await tester.pumpAndSettle();
    await _tapInDialog(tester, l10n.jobFinishWithoutInvoiceAction);

    expect(server.invoices, isEmpty);
    expect(server.movedTo, [23]);
    expect(find.text(l10n.jobStageChangedMessage(_served)), findsOneWidget);
  });

  testWidgets(
    'no drawer open: it opens on the board and the handover goes on',
    (tester) async {
      final server = await _pumpBoard(
        tester,
        _readyPhone()..drawerOpen = false,
      );

      await tester.tap(
        find.text(l10n.jobNextActionButton(l10n.jobHandoverButton)),
      );
      await tester.pumpAndSettle();
      await _tapInDialog(tester, l10n.jobInvoiceButton);

      expect(find.text(l10n.paymentDrawerTitle), findsOneWidget);
      await tester.enterText(_inDialog(find.byType(TextField)), '0');
      await _tapInDialog(tester, l10n.paymentDrawerConfirm);

      expect(server.sessionsStarted, 1);
      // The same invoice, sent again once the drawer is open.
      expect(server.invoices, hasLength(2));
      expect(server.order, isNotNull);

      await _handOverTo(tester, l10n, 'سالم');
      expect(server.movedTo, [5]);
    },
  );

  testWidgets('billing above the agreed price is a question, not a failure', (
    tester,
  ) async {
    final server = await _pumpBoard(tester, _readyPhone(approvedPrice: 100));

    await tester.tap(
      find.text(l10n.jobNextActionButton(l10n.jobHandoverButton)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      _inDialog(find.widgetWithText(TextField, l10n.jobLaborTotalLabel)),
      '150',
    );
    await tester.pumpAndSettle();
    await _tapInDialog(tester, l10n.jobInvoiceButton);

    expect(find.text(l10n.jobOverQuoteTitle), findsOneWidget);
    await _tapInDialog(tester, l10n.jobOverQuoteConfirm);

    expect(server.invoices, hasLength(2));
    expect(server.invoices.last.acknowledgeOverQuote, isTrue);
    expect(server.invoices.last.laborTotal, 150);

    await _handOverTo(tester, l10n, 'سالم');
    expect(server.movedTo, [5]);
  });

  testWidgets('a job billed meanwhile is handed over without asking again', (
    tester,
  ) async {
    final server = await _pumpBoard(tester, _readyPhone());
    // Invoiced at another till after this board last loaded: the card still
    // says unbilled.
    server.order = 138;

    await tester.tap(
      find.text(l10n.jobNextActionButton(l10n.jobHandoverButton)),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.jobInvoiceTitle), findsNothing);
    await _handOverTo(tester, l10n, 'سالم');

    expect(server.invoices, isEmpty);
    expect(server.calls, ['load', 'move', 'board']);
    expect(server.movedTo, [5]);
  });

  testWidgets('a production batch finishing asks nothing about money', (
    tester,
  ) async {
    final server = await _pumpBoard(
      tester,
      _FakeOperationsRepository(
        jobType: 'production',
        stages: _production,
        stageIndex: 1,
      ),
    );

    await tester.tap(find.text(l10n.jobNextActionButton('اكتمل الإنتاج')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.jobInvoiceTitle), findsNothing);
    expect(server.calls, ['move', 'board']);
    expect(server.movedTo, [33]);
  });
}
