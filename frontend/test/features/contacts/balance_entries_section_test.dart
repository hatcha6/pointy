import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/balance_entry.dart';
import 'package:pointy_frontend/src/data/models/money_source.dart';
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
    // Whoever writes balances can always record an amount on the account.
    expect(
      find.byKey(const ValueKey('account_receive_money_button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('account_pay_money_button')),
      findsOneWidget,
    );
    // The untouched opening can be withdrawn; the refund never can — the
    // server says so, and the row shows what the server says.
    expect(
      find.byKey(const ValueKey('cancel_balance_entry_1')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('cancel_balance_entry_3')), findsNothing);
    // Money that left the shop is named by the button that sent it.
    expect(find.text('دفع مبلغ'), findsWidgets);
    expect(find.text('رصيد افتتاحي • دين عليه'), findsOneWidget);
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
      refundableAmount: 50,
    );

    expect(find.byKey(const ValueKey('balance_entry_2')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('add_opening_balance_button')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('account_receive_money_button')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('account_pay_money_button')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('cancel_balance_entry_2')), findsNothing);
    // A debt written without money says so.
    expect(find.text('دفع مبلغ • تسجيل على الحساب'), findsOneWidget);
  });

  testWidgets('an amount recorded without money needs a reason, then writes '
      'and refreshes the account', (tester) async {
    final repository = _FakeBalanceRepository(entries: []);
    var refreshed = 0;
    await _pumpSection(
      tester,
      repository: repository,
      canManage: true,
      canCancel: true,
      onChanged: () async => refreshed += 1,
    );

    await tester.tap(
      find.byKey(const ValueKey('account_receive_money_button')),
    );
    await tester.pumpAndSettle();

    // Nothing is due, so recording on the account is all there is.
    expect(
      find.text('لا يوجد مبلغ مستحق الآن، فيمكن التسجيل على الحساب فقط.'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('record_payment_amount_field')),
      '75.5',
    );
    await tester.tap(find.byKey(const ValueKey('record_payment_confirm')));
    await tester.pumpAndSettle();

    expect(find.text('اكتب السبب.'), findsOneWidget);
    expect(repository.createdDrafts, isEmpty);

    await tester.enterText(
      find.byKey(const ValueKey('record_payment_notes_field')),
      'عربون لم يُسجّل',
    );
    await tester.tap(find.byKey(const ValueKey('record_payment_confirm')));
    await tester.pumpAndSettle();

    // The shop received value, so the customer is owed it.
    final draft = repository.createdDrafts.single;
    expect(draft.kind, BalanceEntryKind.adjustment);
    expect(draft.direction, BalanceDirection.weOweThem);
    expect(draft.amount, 75.5);
    expect(draft.note, 'عربون لم يُسجّل');
    expect(refreshed, 1);
    expect(find.text('تم تسجيل المبلغ'), findsOneWidget);
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

  testWidgets('paying out is capped at what is owed and can come from the '
      'treasury', (tester) async {
    final repository = _FakeBalanceRepository(entries: []);
    var refreshed = 0;
    await _pumpSection(
      tester,
      repository: repository,
      canManage: true,
      canCancel: true,
      canUseDrawer: true,
      canUseTreasury: true,
      refundableAmount: 50,
      onChanged: () async => refreshed += 1,
    );

    await tester.tap(find.byKey(const ValueKey('account_pay_money_button')));
    await tester.pumpAndSettle();

    // Prefilled with everything that can be paid, from the drawer unless
    // the treasury is chosen.
    expect(find.text('50.00'), findsOneWidget);
    await tester.tap(find.text('الخزينة'));
    await tester.enterText(
      find.byKey(const ValueKey('record_payment_amount_field')),
      '60',
    );
    await tester.tap(find.byKey(const ValueKey('record_payment_confirm')));
    await tester.pumpAndSettle();
    expect(repository.refunds, isEmpty);
    expect(find.textContaining('لا يتجاوز 50'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('record_payment_amount_field')),
      '20',
    );
    await tester.enterText(
      find.byKey(const ValueKey('record_payment_notes_field')),
      'طلب رد العربون',
    );
    await tester.tap(find.byKey(const ValueKey('record_payment_confirm')));
    await tester.pumpAndSettle();

    expect(repository.refunds.single, (20.0, 'طلب رد العربون'));
    expect(repository.lastSource, MoneySource.treasury);
    expect(refreshed, 1);
    expect(find.text('تم تسجيل المبلغ'), findsOneWidget);
  });

  testWidgets('a cashier pays through the drawer with no treasury choice, and '
      'is told to open a shift', (tester) async {
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
      canUseDrawer: true,
      refundableAmount: 30,
    );

    await tester.tap(
      find.byKey(const ValueKey('account_receive_money_button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('الخزينة'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('record_payment_confirm')));
    await tester.pumpAndSettle();

    expect(repository.lastSource, MoneySource.drawer);
    expect(
      find.text('افتح وردية أولًا — المبلغ يُصرف أو يُستلم عبر درج الوردية.'),
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
  bool canUseDrawer = false,
  bool canUseTreasury = false,
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
            canUseDrawer: canUseDrawer,
            canUseTreasury: canUseTreasury,
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
  MoneySource? lastSource;
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
    String method = 'cash',
    MoneySource source = MoneySource.drawer,
    int? moneyAccountId,
    String? idempotencyKey,
  }) async {
    lastSettles = settles;
    lastSource = source;
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
