import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/exchange_rate.dart';

void main() {
  group('SettlementInstrument', () {
    test('parses the bank series', () {
      expect(SettlementInstrument.fromJson('bank'), SettlementInstrument.bank);
    });

    test('anything unrecognised is treated as cash', () {
      // Cash is how the overwhelming majority of Libyan shops pay, and an
      // unknown value must not silently become "no rate at all".
      expect(SettlementInstrument.fromJson(null), SettlementInstrument.cash);
      expect(
        SettlementInstrument.fromJson('official'),
        SettlementInstrument.cash,
      );
    });
  });

  group('RateSource', () {
    test('a typed rate is marked as the shop\'s own', () {
      expect(RateSource.fromJson('manual').isManual, isTrue);
    });

    test('an unknown source is treated as coming from the feed', () {
      expect(RateSource.fromJson('whatever'), RateSource.relay);
    });
  });

  group('CurrentRates', () {
    final payload = <String, Object?>{
      'base_code': 'LYD',
      'instrument': 'bank',
      'bank_code': 'ncb',
      'staleness_hours': 12,
      'rates': [
        {
          'from_code': 'USD',
          'to_code': 'LYD',
          'rate': '6.85000000',
          'effective_at': '2026-08-31T10:00:00Z',
          'source': 'relay',
          'instrument': 'cash',
          'bank_code': '',
          'requested_instrument': 'bank',
          'requested_bank_code': 'ncb',
          'is_stale': true,
          'is_substituted': true,
          'inverted': false,
          'age_hours': 30.5,
        },
      ],
    };

    test('parses the shop settlement configuration', () {
      final rates = CurrentRates.fromJson(payload);
      expect(rates.baseCode, 'LYD');
      expect(rates.instrument, SettlementInstrument.bank);
      expect(rates.bankCode, 'ncb');
      expect(rates.stalenessHours, 12);
    });

    test('carries the provenance of each rate', () {
      final rate = CurrentRates.fromJson(payload).rates.single;
      expect(rate.rate, 6.85);
      expect(rate.source, RateSource.relay);
      // Asked for the bank series, served cash — the substitution the UI has
      // to surface rather than hide.
      expect(rate.isSubstituted, isTrue);
      expect(rate.instrument, SettlementInstrument.cash);
      expect(rate.requestedInstrument, SettlementInstrument.bank);
      expect(rate.isStale, isTrue);
    });

    test('surfaces staleness and substitution at the top level', () {
      final rates = CurrentRates.fromJson(payload);
      expect(rates.hasStaleRates, isTrue);
      expect(rates.hasSubstitutions, isTrue);
    });

    test('looks a rate up by currency, case-insensitively', () {
      final rates = CurrentRates.fromJson(payload);
      expect(rates.rateFor('usd')?.rate, 6.85);
      expect(rates.rateFor('EUR'), isNull);
    });

    test('an empty payload is not an error', () {
      final rates = CurrentRates.fromJson(const <String, Object?>{});
      expect(rates.rates, isEmpty);
      expect(rates.baseCode, 'LYD');
    });
  });

  group('ManualRateDraft', () {
    test('omits a bank code for a cash rate', () {
      const draft = ManualRateDraft(
        fromCode: 'USD',
        rate: 7.25,
        bankCode: 'ncb',
      );
      expect(draft.toJson().containsKey('bank_code'), isFalse);
    });

    test('keeps the bank code for a bank rate', () {
      const draft = ManualRateDraft(
        fromCode: 'USD',
        rate: 7.25,
        instrument: SettlementInstrument.bank,
        bankCode: 'ncb',
      );
      expect(draft.toJson()['bank_code'], 'ncb');
    });

    test('sends the rate as text so it is not rounded in transit', () {
      const draft = ManualRateDraft(fromCode: 'USD', rate: 6.85123456);
      expect(draft.toJson()['rate'], '6.85123456');
    });
  });

  group('PriceProposal', () {
    Map<String, Object?> proposal({Object? proposed = '85.32'}) => {
      'kind': 'variant',
      'target_id': 7,
      'product_id': 3,
      'label': 'Imported widget',
      'currency_code': 'USD',
      'price_amount': '12.00',
      'current_base_price': '82.20',
      'proposed_base_price': proposed,
      'old_rate': '6.85000000',
      'new_rate': '7.11000000',
      'delta_percent': '3.80',
      'unpriceable': false,
    };

    test('reports the direction and size of the move', () {
      final parsed = PriceProposal.fromJson(proposal());
      expect(parsed.delta, closeTo(3.12, 0.001));
      expect(parsed.isIncrease, isTrue);
      expect(parsed.deltaPercent, 3.80);
    });

    test('an unpriceable row carries no proposed price', () {
      final parsed = PriceProposal.fromJson({
        ...proposal(proposed: null),
        'unpriceable': true,
      });
      expect(parsed.unpriceable, isTrue);
      expect(parsed.proposedBasePrice, isNull);
      expect(parsed.delta, 0);
    });

    test('identifies itself by kind and id when approved', () {
      final parsed = PriceProposal.fromJson(proposal());
      expect(parsed.toTargetJson(), {'kind': 'variant', 'target_id': 7});
    });
  });

  group('the master switch', () {
    test('defaults to off when the server does not say', () {
      // A shop that predates the flag, or a payload from an older backend,
      // must land on single-currency rather than opening the feature up.
      expect(
        CurrentRates.fromJson(const <String, Object?>{}).fxEnabled,
        isFalse,
      );
      expect(CurrentRates.empty.fxEnabled, isFalse);
    });

    test('is read from the payload when present', () {
      expect(
        CurrentRates.fromJson(const {'fx_enabled': true}).fxEnabled,
        isTrue,
      );
    });
  });
}
