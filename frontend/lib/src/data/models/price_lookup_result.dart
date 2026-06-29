/// A single applied discount, as surfaced by the price-checker lookup endpoint.
class PriceLookupDiscount {
  const PriceLookupDiscount({
    required this.name,
    required this.valueType,
    required this.value,
    required this.amount,
  });

  final String name;

  /// `percentage` or `fixed`.
  final String valueType;

  /// The rule's configured value (e.g. `10.00`).
  final String value;

  /// The amount actually deducted from this item (e.g. `2.00`).
  final String amount;

  bool get isPercentage => valueType == 'percentage';

  factory PriceLookupDiscount.fromJson(Map<String, Object?> json) {
    return PriceLookupDiscount(
      name: json['name']?.toString() ?? '',
      valueType: json['value_type']?.toString() ?? '',
      value: json['value']?.toString() ?? '',
      amount: json['amount']?.toString() ?? '',
    );
  }
}

/// The display-ready result of scanning a barcode at a price checker.
///
/// The backend already runs the discount engine for a walk-up shopper, so the
/// kiosk just renders these fields — money values arrive pre-formatted with the
/// shop currency (`final_price_display`) and discounts are itemised.
class PriceLookupResult {
  const PriceLookupResult({
    required this.found,
    required this.barcode,
    required this.inStock,
    required this.currency,
    this.productName = '',
    this.variantName = '',
    this.sku = '',
    this.unit = '',
    this.originalPrice = '',
    this.finalPrice = '',
    this.discountTotal = '',
    this.discountPercent = 0,
    this.hasDiscount = false,
    this.originalPriceDisplay = '',
    this.finalPriceDisplay = '',
    this.imageUrl = '',
    this.discounts = const [],
  });

  final bool found;
  final String barcode;
  final bool inStock;
  final String currency;
  final String productName;
  final String variantName;
  final String sku;
  final String unit;
  final String originalPrice;
  final String finalPrice;
  final String discountTotal;
  final int discountPercent;
  final bool hasDiscount;
  final String originalPriceDisplay;
  final String finalPriceDisplay;

  /// Absolute, token-signed URL of the product photo, or empty when there is
  /// none. Fetchable without authentication (LAN kiosk friendly).
  final String imageUrl;
  final List<PriceLookupDiscount> discounts;

  bool get hasImage => imageUrl.isNotEmpty;

  /// A variant name worth showing (non-empty and different from the product).
  bool get showsVariant =>
      variantName.isNotEmpty && variantName != productName;

  factory PriceLookupResult.fromJson(Map<String, Object?> json) {
    final discountsJson = json['discounts'];
    return PriceLookupResult(
      found: json['found'] == true,
      barcode: json['barcode']?.toString() ?? '',
      inStock: json['in_stock'] != false,
      currency: json['currency']?.toString() ?? '',
      productName: json['product_name']?.toString() ?? '',
      variantName: json['variant_name']?.toString() ?? '',
      sku: json['sku']?.toString() ?? '',
      unit: json['unit']?.toString() ?? '',
      originalPrice: json['original_price']?.toString() ?? '',
      finalPrice: json['final_price']?.toString() ?? '',
      discountTotal: json['discount_total']?.toString() ?? '',
      discountPercent: switch (json['discount_percent']) {
        final int value => value,
        final num value => value.round(),
        final String value => int.tryParse(value) ?? 0,
        _ => 0,
      },
      hasDiscount: json['has_discount'] == true,
      originalPriceDisplay: json['original_price_display']?.toString() ?? '',
      finalPriceDisplay: json['final_price_display']?.toString() ?? '',
      imageUrl: json['image_url']?.toString() ?? '',
      discounts: discountsJson is List
          ? discountsJson
                .whereType<Map<String, Object?>>()
                .map(PriceLookupDiscount.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}
