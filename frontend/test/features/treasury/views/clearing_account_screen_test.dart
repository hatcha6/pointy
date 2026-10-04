import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/card_settlement.dart';
import 'package:pointy_frontend/src/data/models/money_position.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/treasury_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/treasury/view_models/money_position_view_model.dart';
import 'package:pointy_frontend/src/features/treasury/views/money_position_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';
import '../../../shared/role_fixtures.dart';

/// Card takings Moamalat is holding, as the owner meets them: beside the
/// banks and inside the total, late days called out, and the processor's
/// transfer recorded — or undone — from the treasury itself.
void main() {
  testWidgets('held card money sits beside the banks and inside the total', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('مبيعات بطاقات قيد التسوية'), findsOneWidget);
    expect(find.text('قيد التسوية 148.50 د.ل'), findsOneWidget);
    expect(find.text('648.50 د.ل'), findsOneWidget); // 500 bank + 148.50 held
    expect(find.text('تحويل بطاقات متأخر: 99.00 د.ل'), findsOneWidget);
    expect(find.text('تُحوَّل إلى حساب المحل'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('treasury_record_settlement_button')),
      findsOneWidget,
    );
  });

  testWidgets('an auditor reads held money and cannot record a deposit', (
    tester,
  ) async {
    await _pump(
      tester,
      user: userWithRole(UserRole.auditor, auditorPermissions),
    );

    expect(find.text('مبيعات بطاقات قيد التسوية'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('treasury_record_settlement_button')),
      findsNothing,
    );
  });

  testWidgets('recording the processor transfer from the treasury', (
    tester,
  ) async {
    final repository = await _pump(tester);

    await tester.tap(
      find.byKey(const ValueKey('treasury_record_settlement_button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('تسجيل وصول تحويل'), findsWidgets);

    await tester.enterText(
      find.byKey(const ValueKey('card_settlement_amount_field')),
      '985',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    // The server proposed the overdue day; the owner sees the extra fee.
    expect(
      find.byKey(const ValueKey('card_settlement_difference_note')),
      findsOneWidget,
    );
    expect(
      find.text(
        'احتجزت شركة الدفع 5.00 د.ل أكثر من العمولة المقدّرة، ويُسجَّل الفرق مصروفَ عمولة.',
      ),
      findsOneWidget,
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey('card_settlement_submit_button')),
    );
    await tester.tap(
      find.byKey(const ValueKey('card_settlement_submit_button')),
    );
    await tester.pumpAndSettle();

    final draft = repository.recorded.single;
    expect(draft.days, ['2026-09-25']);
    expect(draft.amountReceivedCents, 98500);
    expect(draft.expectedCents, 99000);
    expect(find.text('سُجِّل وصول التحويل.'), findsOneWidget);
  });

  testWidgets('a recorded settlement can be undone from the account sheet', (
    tester,
  ) async {
    final repository = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('treasury_clearing_card_9')));
    await tester.pumpAndSettle();

    expect(find.text('الأيام قيد التسوية'), findsOneWidget);
    expect(find.text('التحويلات المسجّلة'), findsOneWidget);
    // Held money leaves only by a settlement: no free-typed transfer.
    expect(
      find.byKey(const ValueKey('treasury_details_transfer_button')),
      findsNothing,
    );

    final undo = find.byKey(const ValueKey('treasury_settlement_cancel_41'));
    await tester.ensureVisible(undo);
    await tester.tap(undo);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('treasury_settlement_cancel_reason')),
      'المبلغ خطأ',
    );
    await tester.tap(
      find.byKey(const ValueKey('treasury_settlement_cancel_confirm')),
    );
    await tester.pumpAndSettle();

    expect(repository.cancelled, [(41, 'المبلغ خطأ')]);
    expect(find.text('أُلغيت التسوية.'), findsOneWidget);
  });
}

PosUser _manager() => userWithRole(UserRole.manager, const {});

Future<_FakeRepository> _pump(WidgetTester tester, {PosUser? user}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final repository = _FakeRepository();
  final viewModel = MoneyPositionViewModel(repository);
  addTearDown(viewModel.dispose);
  final navigation = FakeAppNavigation(currentUser: user ?? _manager());

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: MoneyPositionScreen(
          viewModel: viewModel,
          capabilities: navigation.capabilities,
          navigation: navigation,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

const _clearing = MoneyAccount(
  id: 9,
  name: 'معاملات',
  kind: MoneyAccountKind.clearing,
  settlesIntoId: 2,
  settlesIntoName: 'حساب المحل',
  holdsUntaggedCard: true,
);

MoneyPosition _position() {
  return MoneyPosition(
    accounts: [
      const MoneyAccountPosition(
        account: MoneyAccount(
          id: 2,
          name: 'حساب المحل',
          kind: MoneyAccountKind.bank,
          isDefault: true,
          isRouted: true,
        ),
        expectedBalance: 500,
      ),
      MoneyAccountPosition(
        account: _clearing,
        expectedBalance: 148.50,
        components: const [
          MoneyPositionComponent(code: 'sales', amount: 150, isInflow: true),
          MoneyPositionComponent(
            code: 'commission',
            amount: -1.50,
            isInflow: false,
          ),
        ],
        held: HeldSummary(
          days: 2,
          payments: 2,
          oldestDay: DateTime(2026, 9, 25),
          nextExpectedOn: DateTime(2026, 9, 27),
          overdueDays: 1,
          overdueAmount: 99,
        ),
      ),
    ],
    totals: const MoneyPositionTotals(
      bank: 500,
      inTransit: 148.50,
      total: 648.50,
      accountsCounted: 1,
      accountsTotal: 1,
    ),
  );
}

class _FakeRepository extends TreasuryRepository {
  _FakeRepository() : super(PosApiService());

  final List<CardSettlementDraft> recorded = [];
  final List<(int, String)> cancelled = [];

  static final _days = [
    HeldDay(
      day: DateTime(2026, 9, 25),
      expectedOn: DateTime(2026, 9, 27),
      overdue: true,
      netCents: 99000,
      count: 1,
    ),
    HeldDay(
      day: DateTime(2026, 9, 28),
      expectedOn: DateTime(2026, 9, 29),
      netCents: 49500,
      count: 1,
    ),
  ];

  @override
  Future<Result<MoneyPosition>> loadPosition({DateTime? asOf}) async =>
      Ok(_position());

  @override
  Future<Result<MoneyMovementPage>> loadAccountMovements(
    int accountId, {
    DateTime? start,
    DateTime? end,
  }) async => const Ok(MoneyMovementPage(rows: []));

  @override
  Future<Result<HeldTakings>> loadHeldTakings(
    int accountId, {
    int? amountCents,
    DateTime? settledOn,
  }) async {
    return Ok(
      HeldTakings(
        account: _clearing,
        days: _days,
        suggestion: SettlementSuggestion(
          days: const ['2026-09-25'],
          match: amountCents == null
              ? SettlementMatch.due
              : SettlementMatch.close,
          expectedCents: 99000,
          differenceCents: amountCents == null ? null : amountCents - 99000,
        ),
      ),
    );
  }

  @override
  Future<Result<CardSettlement>> recordCardSettlement(
    CardSettlementDraft draft, {
    String? idempotencyKey,
  }) async {
    recorded.add(draft);
    return Ok(
      CardSettlement(
        id: 42,
        settledOn: draft.settledOn,
        amountReceivedCents: draft.amountReceivedCents,
        expectedCents: draft.expectedCents,
        differenceCents: draft.amountReceivedCents - draft.expectedCents,
      ),
    );
  }

  @override
  Future<Result<List<CardSettlement>>> loadCardSettlements(
    int accountId,
  ) async {
    return Ok([
      CardSettlement(
        id: 41,
        settledOn: DateTime(2026, 9, 21),
        amountReceivedCents: 120000,
        expectedCents: 120000,
        differenceCents: 0,
        paymentCount: 4,
        firstDay: DateTime(2026, 9, 18),
        lastDay: DateTime(2026, 9, 20),
      ),
    ]);
  }

  @override
  Future<Result<CardSettlement>> cancelCardSettlement(
    int settlementId, {
    String reason = '',
    String? idempotencyKey,
  }) async {
    cancelled.add((settlementId, reason));
    return Ok(
      CardSettlement(
        id: settlementId,
        settledOn: DateTime(2026, 9, 21),
        amountReceivedCents: 120000,
        expectedCents: 120000,
        differenceCents: 0,
        isCancelled: true,
      ),
    );
  }
}
