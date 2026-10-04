import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/card_settlement.dart';
import 'package:pointy_frontend/src/data/models/money_position.dart';
import 'package:pointy_frontend/src/data/repositories/treasury_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/treasury/view_models/card_settlement_view_model.dart';

/// The settlement sheet's arithmetic and its conversation with the server: the
/// days the server proposes are applied when the amount changes, the owner's
/// own ticks and exclusions are honoured to the cent, and a refusal is shown
/// in the words that fit it.
void main() {
  late _FakeRepository repository;
  late CardSettlementViewModel viewModel;

  setUp(() {
    repository = _FakeRepository();
    viewModel = CardSettlementViewModel(
      repository,
      account: _clearing,
      today: DateTime(2026, 10, 4),
      debounce: Duration.zero,
    );
  });

  tearDown(() => viewModel.dispose());

  test('loading ticks the days the server proposes', () async {
    await viewModel.load();

    expect(viewModel.days, hasLength(3));
    expect(viewModel.isSelected(viewModel.days[0]), isTrue);
    expect(viewModel.isSelected(viewModel.days[1]), isTrue);
    expect(viewModel.isSelected(viewModel.days[2]), isFalse);
    expect(viewModel.expectedCents, 99000 + 49500);
    expect(viewModel.differenceCents, isNull);
    expect(viewModel.canSubmit, isFalse);
  });

  test('typing the deposit asks again and applies the new proposal', () async {
    await viewModel.load();
    repository.suggestedDays = const ['2026-10-01'];

    viewModel.setAmountText('٩٩٠'); // Arabic-Indic digits from the keyboard
    await _settle();

    expect(viewModel.amountCents, 99000);
    expect(repository.amountsAsked.last, 99000);
    expect(viewModel.isSelected(viewModel.days[1]), isFalse);
    expect(viewModel.differenceCents, 0);
    expect(viewModel.canSubmit, isTrue);
  });

  test('the owner can untick a day and leave a sale out', () async {
    await viewModel.load();
    viewModel.setAmountText('1400');
    await _settle();

    final first = viewModel.days[0];
    await viewModel.loadPayments(first);
    viewModel.togglePayment(first, viewModel.paymentsFor(first)!.first);
    expect(viewModel.expectedCents, (99000 - 59400) + 49500);

    viewModel.toggleDay(viewModel.days[1]);
    expect(viewModel.expectedCents, 99000 - 59400);
    expect(viewModel.differenceCents, 140000 - (99000 - 59400));
  });

  test(
    'confirming sends the days, the exclusions and the figure seen',
    () async {
      await viewModel.load();
      viewModel.setAmountText('1480.50');
      await _settle();
      final first = viewModel.days[0];
      await viewModel.loadPayments(first);
      viewModel.togglePayment(first, viewModel.paymentsFor(first)!.first);

      final settlement = await viewModel.submit(reference: ' SMS 77 ');

      expect(settlement, isNotNull);
      final draft = repository.recorded.single;
      expect(draft.days, ['2026-10-01', '2026-10-02']);
      expect(draft.excludePaymentIds, [601]);
      expect(draft.amountReceivedCents, 148050);
      expect(draft.expectedCents, viewModel.expectedCents);
      expect(draft.reference, 'SMS 77');
      expect(draft.settledOn, DateTime(2026, 10, 4));
    },
  );

  test('a closed period or a missing right reads as such', () async {
    await viewModel.load();
    viewModel.setAmountText('990');
    await _settle();
    repository.failWith = const PosApiException(
      message: 'forbidden',
      statusCode: 403,
      responseBody: '{"detail": "The books are closed through 2026-09-30."}',
    );

    expect(await viewModel.submit(), isNull);
    expect(viewModel.failure, CardSettlementFailure.forbidden);
  });

  test("the server's own Arabic refusal is shown as it is", () async {
    await viewModel.load();
    viewModel.setAmountText('990');
    await _settle();
    repository.failWith = const PosApiException(
      message: 'bad request',
      statusCode: 400,
      responseBody:
          '{"detail": "تغيّرت المبالغ قيد التسوية منذ فتح الشاشة.", '
          '"code": "held_amount_changed"}',
    );
    final loadsBefore = repository.amountsAsked.length;

    expect(await viewModel.submit(), isNull);
    await _settle();

    expect(viewModel.failure, CardSettlementFailure.explained);
    expect(viewModel.failureMessage, contains('تغيّرت'));
    // The held takings moved under the owner: they are read again.
    expect(repository.amountsAsked.length, greaterThan(loadsBefore));
  });

  test(
    'an English framework message is never put in front of the owner',
    () async {
      await viewModel.load();
      viewModel.setAmountText('990');
      await _settle();
      repository.failWith = const PosApiException(
        message: 'bad request',
        statusCode: 400,
        responseBody: '{"days": ["This field is required."]}',
      );

      expect(await viewModel.submit(), isNull);
      expect(viewModel.failure, CardSettlementFailure.generic);
    },
  );
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const _clearing = MoneyAccount(
  id: 9,
  name: 'معاملات',
  kind: MoneyAccountKind.clearing,
  settlesIntoId: 2,
  settlesIntoName: 'حساب المحل',
);

class _FakeRepository extends TreasuryRepository {
  _FakeRepository() : super(PosApiService());

  List<String> suggestedDays = const ['2026-10-01', '2026-10-02'];
  final List<int?> amountsAsked = [];
  final List<CardSettlementDraft> recorded = [];
  PosApiException? failWith;

  static final _days = [
    HeldDay(
      day: DateTime(2026, 10, 1),
      expectedOn: DateTime(2026, 10, 4),
      netCents: 99000,
      count: 2,
    ),
    HeldDay(
      day: DateTime(2026, 10, 2),
      expectedOn: DateTime(2026, 10, 4),
      netCents: 49500,
      count: 1,
    ),
    HeldDay(
      day: DateTime(2026, 10, 3),
      expectedOn: DateTime(2026, 10, 4),
      netCents: 20000,
      count: 1,
    ),
  ];

  @override
  Future<Result<HeldTakings>> loadHeldTakings(
    int accountId, {
    int? amountCents,
    DateTime? settledOn,
  }) async {
    amountsAsked.add(amountCents);
    return Ok(
      HeldTakings(
        account: _clearing,
        days: _days,
        suggestion: SettlementSuggestion(
          days: suggestedDays,
          match: SettlementMatch.exact,
        ),
      ),
    );
  }

  @override
  Future<Result<List<HeldPayment>>> loadHeldDayPayments(
    int accountId,
    String day,
  ) async {
    return const Ok([
      HeldPayment(
        id: 601,
        amountCents: 60000,
        commissionCents: 600,
        netCents: 59400,
      ),
      HeldPayment(
        id: 602,
        amountCents: 40000,
        commissionCents: 400,
        netCents: 39600,
      ),
    ]);
  }

  @override
  Future<Result<CardSettlement>> recordCardSettlement(
    CardSettlementDraft draft, {
    String? idempotencyKey,
  }) async {
    final failure = failWith;
    if (failure != null) {
      return Error(failure);
    }
    recorded.add(draft);
    return Ok(
      CardSettlement(
        id: 1,
        settledOn: draft.settledOn,
        amountReceivedCents: draft.amountReceivedCents,
        expectedCents: draft.expectedCents,
        differenceCents: draft.amountReceivedCents - draft.expectedCents,
      ),
    );
  }
}
