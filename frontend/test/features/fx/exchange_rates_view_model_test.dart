import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/exchange_rate.dart';
import 'package:pointy_frontend/src/data/repositories/fx_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/exchange_rates_view_model.dart';

class _FakeFxRepository extends FxRepository {
  _FakeFxRepository() : super(PosApiService());

  CurrentRates rates = CurrentRates.empty;
  List<Currency> currencies = const <Currency>[];
  List<PriceProposal> proposals = const <PriceProposal>[];
  DateTime? resolvedAt = DateTime.utc(2026, 8, 31, 12);
  DateTime? lastResolvedAt;
  Map<String, Object?> syncResult = const <String, Object?>{'synced': 1};
  bool ratesFail = false;
  bool syncFails = false;
  List<PriceProposal>? lastApplied;
  int applyResult = 0;

  @override
  Future<Result<CurrentRates>> loadCurrentRates() async =>
      ratesFail ? Error(Exception('offline')) : Ok(rates);

  @override
  Future<Result<List<Currency>>> loadCurrencies() async => Ok(currencies);

  @override
  Future<Result<RepricePreview>> loadRepricePreview() async =>
      Ok(RepricePreview(resolvedAt: resolvedAt, proposals: proposals));

  @override
  Future<Result<Map<String, Object?>>> syncNow() async =>
      syncFails ? Error(Exception('unreachable')) : Ok(syncResult);

  @override
  Future<Result<int>> applyReprice(
    List<PriceProposal> approved, {
    DateTime? resolvedAt,
  }) async {
    lastApplied = approved;
    lastResolvedAt = resolvedAt;
    return Ok(applyResult);
  }

  @override
  Future<Result<ExchangeRate>> recordManualRate(ManualRateDraft draft) async =>
      Ok(
        ExchangeRate(
          id: 1,
          fromCode: draft.fromCode,
          toCode: draft.toCode ?? 'LYD',
          rate: draft.rate,
          instrument: draft.instrument,
          bankCode: draft.bankCode,
          source: RateSource.manual,
        ),
      );
}

ResolvedRate _rate(String code, {bool stale = false}) => ResolvedRate(
  fromCode: code,
  toCode: 'LYD',
  rate: 6.85,
  effectiveAt: DateTime(2026, 8, 31),
  source: RateSource.relay,
  instrument: SettlementInstrument.cash,
  bankCode: '',
  requestedInstrument: SettlementInstrument.cash,
  requestedBankCode: '',
  isStale: stale,
);

PriceProposal _proposal({
  int id = 1,
  String kind = 'variant',
  bool unpriceable = false,
}) => PriceProposal(
  kind: kind,
  targetId: id,
  productId: id,
  label: 'Item $id',
  currencyCode: 'USD',
  priceAmount: 12,
  currentBasePrice: 82.2,
  proposedBasePrice: unpriceable ? null : 85.32,
  oldRate: 6.85,
  newRate: 7.11,
  deltaPercent: 3.8,
  unpriceable: unpriceable,
);

void main() {
  late _FakeFxRepository repository;
  late ExchangeRatesViewModel viewModel;

  setUp(() {
    repository = _FakeFxRepository();
    viewModel = ExchangeRatesViewModel(repository);
  });

  group('load', () {
    test('exposes the rates and their drift', () async {
      repository.rates = CurrentRates(
        baseCode: 'LYD',
        instrument: SettlementInstrument.cash,
        bankCode: '',
        stalenessHours: 24,
        rates: [_rate('USD')],
      );
      repository.proposals = [_proposal()];

      await viewModel.load();

      expect(viewModel.hasRates, isTrue);
      expect(viewModel.hasDrift, isTrue);
      expect(viewModel.proposals, hasLength(1));
    });

    test('a failed rate load is reported without losing the screen', () async {
      repository.ratesFail = true;
      await viewModel.load();
      expect(viewModel.hasLoadError, isTrue);
      expect(viewModel.hasRates, isFalse);
    });

    test('the shop\'s own currency is not offered as a quotable one', () async {
      repository.rates = const CurrentRates(
        baseCode: 'LYD',
        instrument: SettlementInstrument.cash,
        bankCode: '',
        stalenessHours: 24,
        rates: <ResolvedRate>[],
      );
      repository.currencies = const [
        Currency(
          code: 'LYD',
          nameAr: 'دينار',
          nameEn: 'Dinar',
          symbolAr: 'د.ل',
          symbolEn: 'LYD',
        ),
        Currency(
          code: 'USD',
          nameAr: 'دولار',
          nameEn: 'Dollar',
          symbolAr: r'$',
          symbolEn: r'$',
        ),
      ];

      await viewModel.load();

      expect(viewModel.quotableCurrencies.map((c) => c.code), ['USD']);
    });
  });

  group('sync', () {
    test('a soft failure from the relay is surfaced, not swallowed', () async {
      // The endpoint answers 200 even when the relay was unreachable — that is
      // the soft no-op by design — so the payload decides, not the status.
      repository.syncResult = const {'synced': 0, 'error': 'unreachable'};
      final ok = await viewModel.syncNow();
      expect(ok, isFalse);
      expect(viewModel.lastSyncFailed, isTrue);
    });

    test('a successful sync reports success', () async {
      final ok = await viewModel.syncNow();
      expect(ok, isTrue);
      expect(viewModel.lastSyncFailed, isFalse);
    });

    test('a transport failure is also a soft failure', () async {
      repository.syncFails = true;
      expect(await viewModel.syncNow(), isFalse);
      expect(viewModel.lastSyncFailed, isTrue);
    });
  });

  group('repricing selection', () {
    setUp(() async {
      repository.proposals = [
        _proposal(id: 1),
        _proposal(id: 2),
        _proposal(id: 3, unpriceable: true),
      ];
      await viewModel.load();
    });

    test('nothing is selected by default', () {
      expect(viewModel.selectedProposals, isEmpty);
    });

    test('select-all skips rows that cannot be priced', () {
      viewModel.selectAll();
      expect(viewModel.selectedProposals.map((p) => p.targetId), [1, 2]);
    });

    test('variants and units are tracked separately', () async {
      repository.proposals = [
        _proposal(id: 1, kind: 'variant'),
        _proposal(id: 1, kind: 'unit'),
      ];
      await viewModel.load();
      viewModel.toggle(repository.proposals.first, true);
      expect(viewModel.selectedProposals, hasLength(1));
      expect(viewModel.selectedProposals.single.kind, 'variant');
    });

    test('applying sends only the approved rows', () async {
      viewModel.toggle(repository.proposals.first, true);
      repository.applyResult = 1;
      await viewModel.applySelectedReprice();
      expect(repository.lastApplied, hasLength(1));
      expect(repository.lastApplied!.single.targetId, 1);
    });

    test('applying echoes the instant the preview resolved at', () async {
      // Without this, a rate landing while the owner reads the list would
      // change what gets written and the confirmation would have been a lie.
      viewModel.toggle(repository.proposals.first, true);
      repository.applyResult = 1;
      await viewModel.applySelectedReprice();
      expect(repository.lastResolvedAt, DateTime.utc(2026, 8, 31, 12));
    });

    test('applying nothing does not call the backend', () async {
      final count = await viewModel.applySelectedReprice();
      expect(count, 0);
      expect(repository.lastApplied, isNull);
    });
  });
}
