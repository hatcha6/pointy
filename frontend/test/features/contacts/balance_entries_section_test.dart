import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/balance_entry.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/contacts/view_models/balance_entries_view_model.dart';
import 'package:pointy_frontend/src/features/contacts/views/balance_entries_section.dart';
import 'package:pointy_frontend/src/shared/balance_labels.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

const _opening = BalanceEntry(
  id: 1,
  number: 'B20260101000001',
  kind: BalanceEntryKind.opening,
  direction: BalanceDirection.theyOweUs,
  amount: 100,
  settledAmount: 0,
  remainingAmount: 100,
  canCancel: true,
);

const _settledAdjustment = BalanceEntry(
  id: 2,
  number: 'B20260201000002',
  kind: BalanceEntryKind.adjustment,
  direction: BalanceDirection.theyOweUs,
  amount: 40,
  settledAmount: 15,
  remainingAmount: 25,
  note: 'دين قديم',
);

const _refund = BalanceEntry(
  id: 3,
  number: 'B20260301000003',
  kind: BalanceEntryKind.refund,
  direction: BalanceDirection.theyOweUs,
  amount: 20,
  settledAmount: 20,
  remainingAmount: 0,
);

PosApiException _refusal(String code) {
  return PosApiException(
    message: 'refused',
    statusCode: 400,
    responseBody: jsonEncode({'code': code}),
  );
}

void main() {
  testWidgets('lists the entries and offers what this user may do', (
    tester,
  ) async {
    final repository = _FakeBalanceRepository(entries: [_opening, _refund]);
    await _pumpSection(
      tester,
      repository: repository,
      canManage: true,
      canCancel: true,
    );

    expect(find.byKey(const ValueKey('balance_entry_1')), findsOneWidget);
    expect(find.byKey(const ValueKey('balance_entry_3')), findsOneWidget);
    // A live opening balance stands, so a second is not offered.
    expect(
      find.byKey(const ValueKey('add_opening_balance_button')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('add_balance_adjustment_button')),
      findsOneWidget,
    );
    // The untouched opening can be withdrawn; the refund never can — the
    // server says so, and the row shows what the server says.
    expect(
      find.byKey(const ValueKey('cancel_balance_entry_1')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('cancel_balance_entry_3')), findsNothing);
    // A refund is cash that changed hands: its row names the kind alone.
    expect(find.text('رد مبلغ نقدًا'), findsOneWidget);
    // Nothing credit-side is refundable here.
    expect(find.byKey(const ValueKey('balance_pay_out_button')), findsNothing);
  });

  testWidgets('a read-only user sees the list and nothing to press', (
    tester,
  ) async {
    final repository = _FakeBalanceRepository(entries: [_settledAdjustment]);
    await _pumpSection(
      tester,
      repository: repository,
      canManage: false,
      canCancel: false,
      canRefund: false,
      refundableAmount: 50,
    );

    expect(find.byKey(const ValueKey('balance_entry_2')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('add_opening_balance_button')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('add_balance_adjustment_button')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('balance_pay_out_button')), findsNothing);
    expect(find.byKey(const ValueKey('cancel_balance_entry_2')), findsNothing);
  });

  testWidgets('an adjustment needs a reason, then writes and refreshes the '
      'account', (tester) async {
    final repository = _FakeBalanceRepository(entries: []);
    var refreshed = 0;
    await _pumpSection(
      tester,
      repository: repository,
      canManage: true,
      canCancel: true,
      onChanged: () async => refreshed += 1,
    );

    expect(
      find.text('لا يوجد رصيد افتتاحي أو تسويات على هذا الحساب.'),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('add_balance_adjustment_button')),
    );
    await tester.pumpAndSettle();

    // "له علينا": the shop owes this customer.
    await tester.tap(find.text('له علينا'));
    await tester.enterText(
      find.byKey(const ValueKey('balance_entry_amount')),
      '75.5',
    );
    await tester.tap(find.byKey(const ValueKey('balance_entry_save')));
    await tester.pumpAndSettle();

    expect(find.text('اكتب سبب التسوية.'), findsOneWidget);
    expect(repository.createdDrafts, isEmpty);

    await tester.enterText(
      find.byKey(const ValueKey('balance_entry_note')),
      'عربون لم يُسجّل',
    );
    await tester.tap(find.byKey(const ValueKey('balance_entry_save')));
    await tester.pumpAndSettle();

    final draft = repository.createdDrafts.single;
    expect(draft.kind, BalanceEntryKind.adjustment);
    expect(draft.direction, BalanceDirection.weOweThem);
    expect(draft.amount, 75.5);
    expect(draft.note, 'عربون لم يُسجّل');
    expect(refreshed, 1);
    expect(find.text('تم تسجيل الرصيد.'), findsOneWidget);
  });

  testWidgets('a second opening balance is refused in words, and the dialog '
      'keeps what was typed', (tester) async {
    final repository = _FakeBalanceRepository(
      entries: [],
      createFailure: _refusal('opening_balance_exists'),
    );
    await _pumpSection(
      tester,
      repository: repository,
      canManage: true,
      canCancel: true,
    );

    await tester.tap(find.byKey(const ValueKey('add_opening_balance_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('balance_entry_amount')),
      '10',
    );
    await tester.tap(find.byKey(const ValueKey('balance_entry_save')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'لهذا الحساب رصيد افتتاحي مسجل. ألغِه أولًا أو سجّل تسوية بدلًا منه.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('balance_entry_amount')), findsOneWidget);
  });

  testWidgets('a refund is capped at what is refundable and goes through '
      'the drawer', (tester) async {
    final repository = _FakeBalanceRepository(entries: []);
    var refreshed = 0;
    await _pumpSection(
      tester,
      repository: repository,
      canManage: true,
      canCancel: true,
      canRefund: true,
      refundableAmount: 50,
      onChanged: () async => refreshed += 1,
    );

    await tester.tap(find.byKey(const ValueKey('balance_pay_out_button')));
    await tester.pumpAndSettle();

    // Prefilled with everything that can be refunded.
    expect(find.text('50.00'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('balance_refund_amount')),
      '60',
    );
    await tester.tap(find.byKey(const ValueKey('balance_refund_confirm')));
    await tester.pumpAndSettle();
    expect(repository.refunds, isEmpty);
    expect(find.textContaining('المبلغ أكبر من المتاح'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('balance_refund_amount')),
      '20',
    );
    await tester.enterText(
      find.byKey(const ValueKey('balance_refund_note')),
      'طلب رد العربون',
    );
    await tester.tap(find.byKey(const ValueKey('balance_refund_confirm')));
    await tester.pumpAndSettle();

    expect(repository.refunds.single, (20.0, 'طلب رد العربون'));
    expect(refreshed, 1);
    expect(find.text('تم صرف المبلغ للعميل.'), findsOneWidget);
  });

  testWidgets('a refund without an open shift says so and stays open', (
    tester,
  ) async {
    final repository = _FakeBalanceRepository(
      entries: [],
      refundFailure: _refusal('register_session_required'),
    );
    await _pumpSection(
      tester,
      repository: repository,
      party: BalanceParty.supplier,
      canManage: true,
      canCancel: true,
      canRefund: true,
      refundableAmount: 30,
    );

    expect(find.text('استلام المبلغ من المورد'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('balance_take_in_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('balance_refund_confirm')));
    await tester.pumpAndSettle();

    expect(
      find.text('افتح وردية أولًا — المبلغ يُصرف أو يُستلم عبر درج الوردية.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('balance_refund_confirm')),
      findsOneWidget,
    );
  });

  testWidgets('withdrawing an entry asks why', (tester) async {
    final repository = _FakeBalanceRepository(entries: [_opening]);
    await _pumpSection(
      tester,
      repository: repository,
      canManage: true,
      canCancel: true,
    );

    await tester.tap(find.byKey(const ValueKey('cancel_balance_entry_1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('balance_cancel_reason')),
      'سُجّل بالخطأ',
    );
    await tester.tap(find.byKey(const ValueKey('balance_cancel_confirm')));
    await tester.pumpAndSettle();

    expect(repository.cancelled, [(1, 'سُجّل بالخطأ')]);
    expect(find.text('تم إلغاء الرصيد.'), findsOneWidget);
  });

  group('BalanceEntriesViewModel', () {
    test(
      'a retried write reuses its key; a new write gets a new one',
      () async {
        final repository = _FakeBalanceRepository(
          entries: [],
          createFailure: Exception('timeout'),
        );
        final viewModel = BalanceEntriesViewModel(
          repository: repository,
          party: BalanceParty.customer,
          partyId: 7,
          autoload: false,
        );
        const draft = BalanceEntryDraft(
          kind: BalanceEntryKind.opening,
          direction: BalanceDirection.theyOweUs,
          amount: 10,
        );

        expect(await viewModel.create(draft), BalanceFailure.generic);
        repository.createFailure = null;
        expect(await viewModel.create(draft), isNull);
        expect(repository.createKeys[0], repository.createKeys[1]);

        expect(await viewModel.create(draft), isNull);
        expect(repository.createKeys[2], isNot(repository.createKeys[1]));
        viewModel.dispose();
      },
    );

    test('a cancelled opening does not count as the live one', () async {
      final repository = _FakeBalanceRepository(
        entries: const [
          BalanceEntry(
            id: 9,
            number: 'B1',
            kind: BalanceEntryKind.opening,
            direction: BalanceDirection.theyOweUs,
            amount: 5,
            settledAmount: 0,
            remainingAmount: 5,
            isCancelled: true,
          ),
        ],
      );
      final viewModel = BalanceEntriesViewModel(
        repository: repository,
        party: BalanceParty.supplier,
        partyId: 3,
        autoload: false,
      );
      await viewModel.load();
      expect(viewModel.entries, hasLength(1));
      expect(viewModel.hasLiveOpening, isFalse);
      viewModel.dispose();
    });
  });
}

Future<void> _pumpSection(
  WidgetTester tester, {
  required _FakeBalanceRepository repository,
  BalanceParty party = BalanceParty.customer,
  required bool canManage,
  required bool canCancel,
  bool canRefund = false,
  double refundableAmount = 0,
  Future<void> Function()? onChanged,
}) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      theme: PointyTheme.light(),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: SingleChildScrollView(
          child: BalanceEntriesSection(
            repository: repository,
            party: party,
            partyId: 7,
            canManage: canManage,
            canCancel: canCancel,
            canSettleInCash: canRefund,
            cashPayable: party == BalanceParty.supplier ? 0 : refundableAmount,
            cashCollectable: party == BalanceParty.supplier
                ? refundableAmount
                : 0,
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeBalanceRepository extends ContactRepository {
  _FakeBalanceRepository({
    required List<BalanceEntry> entries,
    this.createFailure,
    this.refundFailure,
  }) : _entries = entries,
       super(PosApiService());

  final List<BalanceEntry> _entries;
  Object? createFailure;
  Object? refundFailure;
  final List<BalanceEntryDraft> createdDrafts = [];
  final List<String?> createKeys = [];
  final List<(double, String)> refunds = [];
  BalanceDirection? lastSettles;
  final List<(int, String)> cancelled = [];

  @override
  Future<Result<BalanceEntryPage>> loadBalanceEntries({
    required BalanceParty party,
    required int partyId,
    int page = 1,
  }) async {
    return Ok(BalanceEntryPage(entries: _entries, hasMore: false));
  }

  @override
  Future<Result<BalanceEntry>> createBalanceEntry({
    required BalanceParty party,
    required int partyId,
    required BalanceEntryDraft draft,
    String? idempotencyKey,
  }) async {
    createKeys.add(idempotencyKey);
    final failure = createFailure;
    if (failure != null) {
      return Error(failure is Exception ? failure : Exception('$failure'));
    }
    createdDrafts.add(draft);
    return Ok(
      BalanceEntry(
        id: 100 + createdDrafts.length,
        number: 'B-new',
        kind: draft.kind,
        direction: draft.direction,
        amount: draft.amount,
        settledAmount: 0,
        remainingAmount: draft.amount,
      ),
    );
  }

  @override
  Future<Result<BalanceEntry>> refundBalance({
    required BalanceParty party,
    required int partyId,
    required double amount,
    String note = '',
    BalanceDirection? settles,
    String? idempotencyKey,
  }) async {
    lastSettles = settles;
    final failure = refundFailure;
    if (failure != null) {
      return Error(failure is Exception ? failure : Exception('$failure'));
    }
    refunds.add((amount, note));
    return Ok(
      BalanceEntry(
        id: 200,
        number: 'B-refund',
        kind: BalanceEntryKind.refund,
        direction: BalanceDirection.theyOweUs,
        amount: amount,
        settledAmount: amount,
        remainingAmount: 0,
      ),
    );
  }

  @override
  Future<Result<BalanceEntry>> cancelBalanceEntry({
    required BalanceParty party,
    required int entryId,
    required String reason,
    String? idempotencyKey,
  }) async {
    cancelled.add((entryId, reason));
    return Ok(_opening);
  }
}
