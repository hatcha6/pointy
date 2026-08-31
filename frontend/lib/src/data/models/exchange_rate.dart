/// Currencies and exchange rates as the apps consume them.
///
/// Every rate carries its provenance, not just its number: where it came from,
/// how old it is, and whether it is the settlement series the shop asked for.
/// The UI is expected to surface all three — a rate shown without its age is the
/// same mistake as a total shown without its currency.
library;

/// How a shop pays for foreign goods.
///
/// Both values are **parallel-market** rates. `bank` is not the official CBL
/// rate: it is the parallel rate for settling through a bank — a transfer, a
/// letter of credit, a certificate — rather than in physical cash, and it is
/// published per bank because that price differs between them. The question this
/// answers is *how does this shop pay*, never *which market*.
enum SettlementInstrument {
  cash,
  bank;

  static SettlementInstrument fromJson(Object? value) {
    return switch (value?.toString().trim().toLowerCase()) {
      'bank' => SettlementInstrument.bank,
      _ => SettlementInstrument.cash,
    };
  }

  String get wireValue => name;
}

/// Where a rate came from.
enum RateSource {
  builtin,
  relay,
  manual;

  static RateSource fromJson(Object? value) {
    return switch (value?.toString().trim().toLowerCase()) {
      'manual' => RateSource.manual,
      'builtin' => RateSource.builtin,
      _ => RateSource.relay,
    };
  }

  /// A rate the shop typed outranks the feed, so the UI marks it.
  bool get isManual => this == RateSource.manual;
}

class Currency {
  const Currency({
    required this.code,
    required this.nameAr,
    required this.nameEn,
    required this.symbolAr,
    required this.symbolEn,
    this.decimals = 2,
    this.displayOrder = 0,
    this.isEnabled = true,
  });

  final String code;
  final String nameAr;
  final String nameEn;
  final String symbolAr;
  final String symbolEn;
  final int decimals;
  final int displayOrder;
  final bool isEnabled;

  /// The symbol to render, falling back to the code so an unknown currency
  /// still shows something meaningful rather than nothing.
  String get symbol =>
      symbolAr.isNotEmpty ? symbolAr : (symbolEn.isNotEmpty ? symbolEn : code);

  String get name => nameAr.isNotEmpty ? nameAr : nameEn;

  factory Currency.fromJson(Map<String, Object?> json) {
    return Currency(
      code: json['code']?.toString() ?? '',
      nameAr: json['name_ar']?.toString() ?? '',
      nameEn: json['name_en']?.toString() ?? '',
      symbolAr: json['symbol_ar']?.toString() ?? '',
      symbolEn: json['symbol_en']?.toString() ?? '',
      decimals: _asInt(json['decimals']) ?? 2,
      displayOrder: _asInt(json['display_order']) ?? 0,
      isEnabled: json['is_enabled'] as bool? ?? true,
    );
  }
}

/// A rate resolved for right now, with everything needed to explain it.
class ResolvedRate {
  const ResolvedRate({
    required this.fromCode,
    required this.toCode,
    required this.rate,
    required this.effectiveAt,
    required this.source,
    required this.instrument,
    required this.bankCode,
    required this.requestedInstrument,
    required this.requestedBankCode,
    this.isStale = false,
    this.isSubstituted = false,
    this.inverted = false,
    this.ageHours = 0,
  });

  final String fromCode;
  final String toCode;
  final double rate;
  final DateTime? effectiveAt;
  final RateSource source;
  final SettlementInstrument instrument;
  final String bankCode;
  final SettlementInstrument requestedInstrument;
  final String requestedBankCode;

  /// Older than the shop's staleness threshold. Never an error — an old rate
  /// still prices — but it must be visible.
  final bool isStale;

  /// A different settlement series than the shop asked for was used, because
  /// theirs had no rate. Surfaced rather than hidden: costing imports off the
  /// wrong instrument is a silent error otherwise.
  final bool isSubstituted;
  final bool inverted;
  final double ageHours;

  factory ResolvedRate.fromJson(Map<String, Object?> json) {
    return ResolvedRate(
      fromCode: json['from_code']?.toString() ?? '',
      toCode: json['to_code']?.toString() ?? '',
      rate: _asDouble(json['rate']) ?? 0,
      effectiveAt: _asDate(json['effective_at']),
      source: RateSource.fromJson(json['source']),
      instrument: SettlementInstrument.fromJson(json['instrument']),
      bankCode: json['bank_code']?.toString() ?? '',
      requestedInstrument: SettlementInstrument.fromJson(
        json['requested_instrument'],
      ),
      requestedBankCode: json['requested_bank_code']?.toString() ?? '',
      isStale: json['is_stale'] as bool? ?? false,
      isSubstituted: json['is_substituted'] as bool? ?? false,
      inverted: json['inverted'] as bool? ?? false,
      ageHours: _asDouble(json['age_hours']) ?? 0,
    );
  }
}

/// The whole current-rates picture for the shop.
class CurrentRates {
  const CurrentRates({
    required this.baseCode,
    required this.instrument,
    required this.bankCode,
    required this.stalenessHours,
    required this.rates,
    this.fxEnabled = false,
  });

  final String baseCode;
  final SettlementInstrument instrument;
  final String bankCode;
  final int stalenessHours;
  final List<ResolvedRate> rates;

  /// The shop's master switch. Off — the default, and the right answer for a
  /// shop that trades only in its own currency — means no currency picker
  /// appears anywhere: not on the product form, not on a purchase order.
  final bool fxEnabled;

  static const empty = CurrentRates(
    baseCode: 'LYD',
    instrument: SettlementInstrument.cash,
    bankCode: '',
    stalenessHours: 24,
    rates: <ResolvedRate>[],
  );

  bool get hasStaleRates => rates.any((rate) => rate.isStale);
  bool get hasSubstitutions => rates.any((rate) => rate.isSubstituted);

  ResolvedRate? rateFor(String currencyCode) {
    final wanted = currencyCode.trim().toUpperCase();
    for (final rate in rates) {
      if (rate.fromCode == wanted) {
        return rate;
      }
    }
    return null;
  }

  factory CurrentRates.fromJson(Map<String, Object?> json) {
    final rows = (json['rates'] as List<Object?>? ?? const <Object?>[])
        .whereType<Map<String, Object?>>()
        .map(ResolvedRate.fromJson)
        .toList();
    return CurrentRates(
      baseCode: json['base_code']?.toString() ?? 'LYD',
      instrument: SettlementInstrument.fromJson(json['instrument']),
      bankCode: json['bank_code']?.toString() ?? '',
      stalenessHours: _asInt(json['staleness_hours']) ?? 24,
      rates: rows,
      fxEnabled: json['fx_enabled'] as bool? ?? false,
    );
  }
}

/// One stored rate row — the audit trail of what the shop knew and when.
class ExchangeRate {
  const ExchangeRate({
    required this.id,
    required this.fromCode,
    required this.toCode,
    required this.rate,
    required this.instrument,
    required this.bankCode,
    required this.source,
    this.effectiveAt,
    this.note = '',
  });

  final int id;
  final String fromCode;
  final String toCode;
  final double rate;
  final SettlementInstrument instrument;
  final String bankCode;
  final RateSource source;
  final DateTime? effectiveAt;
  final String note;

  factory ExchangeRate.fromJson(Map<String, Object?> json) {
    return ExchangeRate(
      id: _asInt(json['id']) ?? 0,
      fromCode: json['from_code']?.toString() ?? '',
      toCode: json['to_code']?.toString() ?? '',
      rate: _asDouble(json['rate']) ?? 0,
      instrument: SettlementInstrument.fromJson(json['instrument']),
      bankCode: json['bank_code']?.toString() ?? '',
      source: RateSource.fromJson(json['source']),
      effectiveAt: _asDate(json['effective_at']),
      note: json['note']?.toString() ?? '',
    );
  }
}

/// A rate the owner is entering by hand.
class ManualRateDraft {
  const ManualRateDraft({
    required this.fromCode,
    required this.rate,
    this.toCode,
    this.instrument = SettlementInstrument.cash,
    this.bankCode = '',
    this.note = '',
  });

  final String fromCode;
  final String? toCode;
  final double rate;
  final SettlementInstrument instrument;
  final String bankCode;
  final String note;

  Map<String, Object?> toJson() => <String, Object?>{
    'from_code': fromCode,
    if (toCode != null && toCode!.isNotEmpty) 'to_code': toCode,
    'rate': rate.toString(),
    'instrument': instrument.wireValue,
    if (instrument == SettlementInstrument.bank && bankCode.isNotEmpty)
      'bank_code': bankCode,
    if (note.isNotEmpty) 'note': note,
  };
}

/// One row's foreign price restated at a newer rate.
class PriceProposal {
  const PriceProposal({
    required this.kind,
    required this.targetId,
    required this.productId,
    required this.label,
    required this.currencyCode,
    required this.priceAmount,
    required this.currentBasePrice,
    required this.proposedBasePrice,
    required this.oldRate,
    required this.newRate,
    required this.deltaPercent,
    this.unpriceable = false,
  });

  final String kind;
  final int targetId;
  final int productId;
  final String label;
  final String currencyCode;
  final double priceAmount;
  final double currentBasePrice;
  final double? proposedBasePrice;
  final double? oldRate;
  final double? newRate;
  final double deltaPercent;

  /// No rate could be resolved for this product's currency at all. Reported
  /// rather than skipped: a product the shop cannot price is exactly what the
  /// owner needs told about.
  final bool unpriceable;

  double get delta =>
      (proposedBasePrice ?? currentBasePrice) - currentBasePrice;
  bool get isIncrease => delta > 0;

  Map<String, Object?> toTargetJson() => <String, Object?>{
    'kind': kind,
    'target_id': targetId,
  };

  factory PriceProposal.fromJson(Map<String, Object?> json) {
    return PriceProposal(
      kind: json['kind']?.toString() ?? 'variant',
      targetId: _asInt(json['target_id']) ?? 0,
      productId: _asInt(json['product_id']) ?? 0,
      label: json['label']?.toString() ?? '',
      currencyCode: json['currency_code']?.toString() ?? '',
      priceAmount: _asDouble(json['price_amount']) ?? 0,
      currentBasePrice: _asDouble(json['current_base_price']) ?? 0,
      proposedBasePrice: _asDouble(json['proposed_base_price']),
      oldRate: _asDouble(json['old_rate']),
      newRate: _asDouble(json['new_rate']),
      deltaPercent: _asDouble(json['delta_percent']) ?? 0,
      unpriceable: json['unpriceable'] as bool? ?? false,
    );
  }
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString().trim() ?? '');
}

double? _asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) return null;
  return double.tryParse(raw);
}

DateTime? _asDate(Object? value) {
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}

/// A repricing preview: the proposals, plus the instant they were resolved at.
///
/// The instant is echoed back on apply so the confirmation the owner saw is the
/// one that gets written, even if a new rate lands while the dialog is open.
class RepricePreview {
  const RepricePreview({required this.resolvedAt, required this.proposals});

  final DateTime? resolvedAt;
  final List<PriceProposal> proposals;

  static const empty = RepricePreview(
    resolvedAt: null,
    proposals: <PriceProposal>[],
  );

  factory RepricePreview.fromJson(Map<String, Object?> json) {
    return RepricePreview(
      resolvedAt: _asDate(json['resolved_at']),
      proposals: (json['proposals'] as List<Object?>? ?? const <Object?>[])
          .whereType<Map<String, Object?>>()
          .map(PriceProposal.fromJson)
          .toList(),
    );
  }
}
