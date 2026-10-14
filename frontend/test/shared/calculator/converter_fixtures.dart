import 'package:pointy_frontend/src/data/models/exchange_rate.dart';
import 'package:pointy_frontend/src/shared/calculator/currency_converter.dart';

/// The shop's currency registry, as `currencies/` returns it.
const sampleRegistry = <Currency>[
  Currency(
    code: 'LYD',
    nameAr: 'دينار ليبي',
    nameEn: 'Libyan Dinar',
    symbolAr: 'د.ل',
    symbolEn: 'LD',
    decimals: 3,
  ),
  Currency(
    code: 'USD',
    nameAr: 'دولار أمريكي',
    nameEn: 'US Dollar',
    symbolAr: '\$',
    symbolEn: '\$',
    displayOrder: 1,
  ),
  Currency(
    code: 'EUR',
    nameAr: 'يورو',
    nameEn: 'Euro',
    symbolAr: '€',
    symbolEn: '€',
    displayOrder: 2,
  ),
  Currency(
    code: 'TND',
    nameAr: 'دينار تونسي',
    nameEn: 'Tunisian Dinar',
    symbolAr: 'د.ت',
    symbolEn: 'DT',
    decimals: 3,
    displayOrder: 3,
  ),
  // In the registry, but Fulus has no rate for it today.
  Currency(
    code: 'GBP',
    nameAr: 'جنيه إسترليني',
    nameEn: 'Pound Sterling',
    symbolAr: '£',
    symbolEn: '£',
    displayOrder: 4,
  ),
];

ResolvedRate sampleRate(
  String code,
  double rate, {
  String toCode = 'LYD',
  double ageHours = 2,
  bool stale = false,
  bool substituted = false,
}) => ResolvedRate(
  fromCode: code,
  toCode: toCode,
  rate: rate,
  effectiveAt: DateTime(2026, 10, 13, 10),
  source: RateSource.relay,
  instrument: SettlementInstrument.cash,
  bankCode: '',
  requestedInstrument: SettlementInstrument.cash,
  requestedBankCode: '',
  isStale: stale,
  isSubstituted: substituted,
  ageHours: ageHours,
);

CurrentRates sampleCurrentRates({
  bool withoutUsd = false,
  bool staleEur = false,
}) => CurrentRates(
  baseCode: 'LYD',
  instrument: SettlementInstrument.cash,
  bankCode: '',
  stalenessHours: 24,
  fxEnabled: true,
  rates: [
    if (!withoutUsd) sampleRate('USD', 7.15),
    sampleRate('EUR', 7.8, stale: staleEur, ageHours: staleEur ? 50 : 2),
    sampleRate('TND', 2.3),
  ],
);

ConverterRates sampleConverterRates({required DateTime loadedAt}) =>
    ConverterRates.from(
      sampleCurrentRates(),
      sampleRegistry,
      loadedAt: loadedAt,
    );
