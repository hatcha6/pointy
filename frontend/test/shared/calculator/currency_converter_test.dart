import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/exchange_rate.dart';
import 'package:pointy_frontend/src/shared/calculator/calculator_number.dart';
import 'package:pointy_frontend/src/shared/calculator/currency_converter.dart';

import '../../support/key_value_store_testing.dart';
import 'converter_fixtures.dart';

CalculatorNumber n(String text) => CalculatorNumber.tryParse(text)!;

void main() {
  final now = DateTime(2026, 10, 13, 12);

  group('ConverterRates.from', () {
    final rates = sampleConverterRates(loadedAt: now);

    test('offers the base first, then foreign currencies that have a rate', () {
      expect(rates.currencies.map((c) => c.code), ['LYD', 'USD', 'EUR', 'TND']);
      // GBP is in the registry but has no rate: not offered.
      expect(rates.currency('GBP'), isNull);
    });

    test('reads each rate from its decimal text, exactly', () {
      expect(rates.rates['USD']!.valueInBase, n('7.15'));
      expect(rates.rates['EUR']!.valueInBase, n('7.8'));
    });

    test('ignores a rate quoted into some other currency or not positive', () {
      final odd = ConverterRates.from(
        CurrentRates(
          baseCode: 'LYD',
          instrument: SettlementInstrument.cash,
          bankCode: '',
          stalenessHours: 24,
          rates: [
            sampleRate('USD', 0),
            sampleRate('EUR', 7.8, toCode: 'USD'),
          ],
        ),
        sampleRegistry,
        loadedAt: now,
      );
      expect(odd.hasForeign, isFalse);
    });
  });

  group('conversion maths', () {
    final rates = sampleConverterRates(loadedAt: now);

    test('foreign → base and back, exactly', () {
      expect(rates.convert(n('240'), 'USD', 'LYD'), n('1716'));
      expect(rates.convert(n('1716'), 'LYD', 'USD'), n('240'));
    });

    test('foreign → foreign goes through the base currency', () {
      // 240 × 7.15 ÷ 7.8 = 220 exactly.
      expect(rates.convert(n('240'), 'USD', 'EUR'), n('220'));
      // 1 USD in TND: 7.15 / 2.3 — kept as a fraction, rounded only to show.
      final tnd = rates.convert(n('1'), 'USD', 'TND')!;
      expect(tnd.formatMoney(3), '3.109');
    });

    test('same currency is identity; an unknown one is null', () {
      expect(rates.convert(n('5'), 'USD', 'USD'), n('5'));
      expect(rates.convert(n('5'), 'GBP', 'LYD'), isNull);
    });

    test('formatMoney pads to the currency and rounds half up', () {
      expect(n('35.94').formatMoney(3), '35.940');
      expect(n('0.7').formatMoney(2), '0.70');
      expect(n('1234.5').formatMoney(2), '1,234.50');
      expect(n('0.005').formatMoney(2), '0.01');
      expect(n('-2.5').formatMoney(0, minusSign: '-'), '-3');
      expect(CalculatorNumber.zero.formatMoney(3), '0.000');
    });
  });

  group('CurrencyConverter', () {
    late int loads;
    late Completer<Result<ConverterRates>>? gate;
    late Result<ConverterRates> Function() answer;
    late DateTime clock;

    CurrencyConverter make() => CurrencyConverter(
      clock: () => clock,
      loader: () async {
        loads++;
        if (gate != null) {
          return gate!.future;
        }
        return answer();
      },
    );

    setUp(() {
      loads = 0;
      gate = null;
      clock = now;
      answer = () => Ok(sampleConverterRates(loadedAt: clock));
    });

    test(
      'defaults to USD on top (the input) and the shop currency below',
      () async {
        final c = make();
        await c.refresh();
        expect(c.topCode, 'USD');
        expect(c.bottomCode, 'LYD');
        expect(c.inputCode, 'USD');
        expect(c.isReady, isTrue);
        expect(c.convertRounded(n('100'))!.formatMoney(3), '715.000');
      },
    );

    test('without USD the first foreign currency is the default', () async {
      answer = () => Ok(
        ConverterRates.from(
          sampleCurrentRates(withoutUsd: true),
          sampleRegistry,
          loadedAt: clock,
        ),
      );
      final c = make();
      await c.refresh();
      expect(c.topCode, 'EUR');
    });

    test('swap keeps the number and flips the direction', () async {
      final c = make();
      await c.refresh();
      expect(c.convert(n('240')), n('1716'));
      c.swap();
      expect(c.inputCode, 'LYD');
      expect(c.outputCode, 'USD');
      expect(c.convertRounded(n('240'))!.formatMoney(2), '33.57');
    });

    test('the other row\'s currency cannot be picked', () async {
      final c = make();
      await c.refresh();
      expect(c.canPick('LYD', top: true), isFalse);
      expect(c.pick('LYD', top: true), isFalse);
      expect(c.topCode, 'USD');
      expect(c.pick('EUR', top: true), isTrue);
      expect(c.topCode, 'EUR');
    });

    test('an unoffered currency cannot be picked', () async {
      final c = make();
      await c.refresh();
      expect(c.pick('GBP', top: true), isFalse);
    });

    test('recents: newest first, no repeats, capped', () async {
      final c = make();
      await c.refresh();
      c.pick('EUR', top: true);
      c.pick('TND', top: true);
      c.pick('EUR', top: true);
      expect(c.recents, ['EUR', 'TND']);
      for (final code in ['USD', 'TND', 'EUR', 'USD', 'TND']) {
        c.pick(code, top: true);
      }
      expect(c.recents.length, lessThanOrEqualTo(4));
      expect(c.recents.first, 'TND');
    });

    test('rates are not refetched while fresh; force always fetches', () async {
      final c = make();
      c.setEnabled(true);
      await c.refresh();
      expect(loads, 1);
      clock = clock.add(const Duration(minutes: 5));
      await c.refresh();
      expect(loads, 1);
      await c.refresh(force: true);
      expect(loads, 2);
      clock = clock.add(const Duration(minutes: 11));
      await c.refresh();
      expect(loads, 3);
    });

    test('concurrent refreshes share one request', () async {
      final c = make();
      gate = Completer();
      final a = c.refresh(force: true);
      final b = c.refresh(force: true);
      expect(c.status, ConverterStatus.loading);
      gate!.complete(Ok(sampleConverterRates(loadedAt: clock)));
      await Future.wait([a, b]);
      expect(loads, 1);
      expect(c.status, ConverterStatus.ready);
    });

    test('a failed refresh keeps the last good rates and says so', () async {
      final c = make();
      await c.refresh();
      answer = () => Error(Exception('offline'));
      await c.refresh(force: true);
      expect(c.status, ConverterStatus.ready);
      expect(c.lastRefreshFailed, isTrue);
      expect(c.convert(n('1')), n('7.15'));
      // And the next plain refresh tries again rather than trusting them.
      answer = () => Ok(sampleConverterRates(loadedAt: clock));
      await c.refresh();
      expect(c.lastRefreshFailed, isFalse);
    });

    test('failing with no rates at all is "failed"', () async {
      answer = () => Error(Exception('offline'));
      final c = make();
      await c.refresh();
      expect(c.status, ConverterStatus.failed);
      expect(c.isReady, isFalse);
      expect(c.convert(n('1')), isNull);
    });

    test('without a loader nothing is offered', () async {
      final c = CurrencyConverter();
      c.setEnabled(true);
      expect(c.isAvailable, isFalse);
      expect(c.enabled, isFalse);
      await c.refresh();
      expect(c.status, ConverterStatus.idle);
    });

    test('reset (signed out) forgets the rates, keeps the pair', () async {
      final c = make();
      await c.refresh();
      c.pick('EUR', top: true);
      c.reset();
      expect(c.rates, isNull);
      expect(c.isAvailable, isFalse);
      expect(c.topCode, 'EUR');
    });

    test('pair rates carry staleness and substitution', () async {
      answer = () => Ok(
        ConverterRates.from(
          sampleCurrentRates(staleEur: true),
          sampleRegistry,
          loadedAt: clock,
        ),
      );
      final c = make();
      await c.refresh();
      expect(c.pairRates.single.code, 'USD');
      expect(c.pairRates.single.isStale, isFalse);
      c.pick('EUR', top: true);
      expect(c.pairRates.single.isStale, isTrue);
      expect(c.pairRates.single.ageHours, 50);
    });
  });

  group('remembering', () {
    test('the pair, side, recents and the toggle survive a restart', () async {
      final store = installMemoryKeyValueStore();
      final first = CurrencyConverter(
        loader: () async => Ok(sampleConverterRates(loadedAt: now)),
      );
      await first.refresh();
      first.setEnabled(true);
      first.pick('EUR', top: true);
      first.swap();
      await pumpEventQueue();
      final saved =
          jsonDecode((await store.getString(CurrencyConverter.storageKey))!)
              as Map<String, Object?>;
      expect(saved['top'], 'EUR');

      final second = CurrencyConverter(
        loader: () async => Ok(sampleConverterRates(loadedAt: now)),
      );
      await pumpEventQueue();
      await second.refresh();
      expect(second.enabled, isTrue);
      expect(second.topCode, 'EUR');
      expect(second.bottomCode, 'LYD');
      expect(second.inputIsTop, isFalse);
      expect(second.recents, ['EUR']);
    });

    test(
      'a remembered currency that is no longer offered falls back',
      () async {
        installMemoryKeyValueStore({
          CurrencyConverter.storageKey: jsonEncode({
            'top': 'GBP',
            'bottom': 'LYD',
            'input_top': true,
            'recents': ['GBP', 'EUR'],
          }),
        });
        final c = CurrencyConverter(
          loader: () async => Ok(sampleConverterRates(loadedAt: now)),
        );
        await pumpEventQueue();
        await c.refresh();
        expect(c.topCode, 'USD');
        expect(c.recents, ['EUR']);
      },
    );

    test('a corrupt saved value is ignored', () async {
      installMemoryKeyValueStore({CurrencyConverter.storageKey: '{not json'});
      final c = CurrencyConverter(
        loader: () async => Ok(sampleConverterRates(loadedAt: now)),
      );
      await pumpEventQueue();
      await c.refresh();
      expect(c.topCode, 'USD');
    });
  });
}
