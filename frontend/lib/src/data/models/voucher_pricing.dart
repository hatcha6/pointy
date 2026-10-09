/// How the shop prices «كروت دفتر»: follow the company's suggested price or
/// its own. Money arrives as strings; every read here is tolerant.
double? pricingNumber(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value.trim());
  }
  return null;
}

String _text(Object? value) => value is String ? value : '';

enum PricingMode {
  company,
  custom;

  static PricingMode parse(Object? value) =>
      value == 'custom' ? PricingMode.custom : PricingMode.company;
}

/// The worked example under one service: what it costs, what the shop pays,
/// the company's suggested price and the shop's own.
class PricingExample {
  const PricingExample({
    this.costHint,
    this.shopPays,
    this.companyPrice,
    this.yourPrice,
  });

  factory PricingExample.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const <String, Object?>{};
    return PricingExample(
      costHint: pricingNumber(map['cost_hint']),
      shopPays: pricingNumber(map['shop_pays']),
      companyPrice: pricingNumber(map['company_price']),
      yourPrice: pricingNumber(map['your_price']),
    );
  }

  final double? costHint;
  final double? shopPays;
  final double? companyPrice;
  final double? yourPrice;
}

class PricingService {
  const PricingService({
    required this.key,
    this.label = '',
    this.mode = PricingMode.company,
    this.markupPercent,
    this.country,
    this.example = const PricingExample(),
  });

  factory PricingService.fromJson(Map<String, Object?> json) => PricingService(
    key: _text(json['key']),
    label: _text(json['label']),
    mode: PricingMode.parse(json['mode']),
    markupPercent: pricingNumber(json['markup_percent']),
    country: json['country'] is String && (json['country'] as String).isNotEmpty
        ? json['country'] as String
        : null,
    example: PricingExample.fromJson(json['example']),
  );

  final String key;
  final String label;
  final PricingMode mode;
  final double? markupPercent;

  /// Set on a per-country row only.
  final String? country;
  final PricingExample example;

  PricingService copyWith({PricingMode? mode, double? markupPercent}) =>
      PricingService(
        key: key,
        label: label,
        mode: mode ?? this.mode,
        markupPercent: markupPercent ?? this.markupPercent,
        country: country,
        example: example,
      );

  Map<String, Object?> toJson() => {
    'key': key,
    if (country != null) 'country': country,
    'mode': mode.name,
    'markup_percent': mode == PricingMode.custom ? markupPercent : null,
  };
}

/// The company's own formula, shown as a hint.
class CompanyPricingRule {
  const CompanyPricingRule({this.fixedLyd, this.shopSharePercent});

  factory CompanyPricingRule.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const <String, Object?>{};
    return CompanyPricingRule(
      fixedLyd: pricingNumber(map['fixed_lyd']),
      shopSharePercent: pricingNumber(map['shop_share_percent']),
    );
  }

  final double? fixedLyd;
  final double? shopSharePercent;
}

class VoucherPricing {
  const VoucherPricing({
    this.defaultMode = PricingMode.company,
    this.defaultMarkupPercent,
    this.services = const [],
    this.companyRule = const CompanyPricingRule(),
  });

  factory VoucherPricing.fromJson(Map<String, Object?> json) => VoucherPricing(
    defaultMode: PricingMode.parse(json['default_mode']),
    defaultMarkupPercent: pricingNumber(json['default_markup_percent']),
    services: [
      for (final row in (json['services'] as List?) ?? const [])
        if (row is Map<String, Object?>) PricingService.fromJson(row),
    ].where((s) => s.key.isNotEmpty).toList(growable: false),
    companyRule: CompanyPricingRule.fromJson(json['company_rule']),
  );

  final PricingMode defaultMode;
  final double? defaultMarkupPercent;
  final List<PricingService> services;
  final CompanyPricingRule companyRule;

  VoucherPricing copyWith({
    PricingMode? defaultMode,
    double? defaultMarkupPercent,
    List<PricingService>? services,
  }) => VoucherPricing(
    defaultMode: defaultMode ?? this.defaultMode,
    defaultMarkupPercent: defaultMarkupPercent ?? this.defaultMarkupPercent,
    services: services ?? this.services,
    companyRule: companyRule,
  );

  /// The body of the PUT: it replaces every service rule, so every row goes.
  Map<String, Object?> toJson() => {
    'default_mode': defaultMode.name,
    'default_markup_percent': defaultMode == PricingMode.custom
        ? defaultMarkupPercent
        : null,
    'services': [for (final s in services) s.toJson()],
  };
}

/// One card variant with the price it is sold at.
class CardPriceRow {
  const CardPriceRow({
    required this.variantId,
    this.name = '',
    this.brand = '',
    this.shopPays,
    this.companyPrice,
    this.mode = PricingMode.company,
    this.customPrice,
    this.belowCost = false,
  });

  factory CardPriceRow.fromJson(Map<String, Object?> json) => CardPriceRow(
    variantId: (json['variant_id'] as num?)?.toInt() ?? 0,
    name: _text(json['name']),
    brand: _text(json['brand']),
    shopPays: pricingNumber(json['shop_pays']),
    companyPrice: pricingNumber(json['company_price']),
    mode: PricingMode.parse(json['mode']),
    customPrice: pricingNumber(json['custom_price']),
    belowCost: json['below_cost'] == true,
  );

  final int variantId;
  final String name;
  final String brand;
  final double? shopPays;
  final double? companyPrice;
  final PricingMode mode;
  final double? customPrice;

  /// The shop's own price is under what the shop now pays the company, so the
  /// card is not sold until the price is fixed.
  final bool belowCost;

  /// What the till sells it for.
  double? get sellingPrice =>
      mode == PricingMode.custom ? customPrice : companyPrice;
}

class CardPricePage {
  const CardPricePage({
    this.rows = const [],
    this.count = 0,
    this.page = 1,
    this.hasMore = false,
    this.belowCostCount = 0,
  });

  factory CardPricePage.fromJson(Map<String, Object?> json) => CardPricePage(
    rows: [
      for (final row in (json['results'] as List?) ?? const [])
        if (row is Map<String, Object?>) CardPriceRow.fromJson(row),
    ],
    count: (json['count'] as num?)?.toInt() ?? 0,
    page: (json['page'] as num?)?.toInt() ?? 1,
    hasMore: json['has_more'] == true,
    belowCostCount: (json['below_cost_count'] as num?)?.toInt() ?? 0,
  );

  final List<CardPriceRow> rows;
  final int count;
  final int page;
  final bool hasMore;

  /// Every card of the shop blocked for being priced under cost, whatever page.
  final int belowCostCount;
}
