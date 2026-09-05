/// A currency the shop may price in.
///
/// Copied verbatim from main's `exchange_rate.dart`, which also carries the
/// rate, repricing and manual-rate models. Those belong to the exchange-rates
/// settings page and the catalog's repricing flow — neither of which this
/// Windows-8 till build has — so only the one class the POS needs lives here.
/// Keep it byte-compatible with main's: the shape is the API's.
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

int? _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? '').toString());
}
