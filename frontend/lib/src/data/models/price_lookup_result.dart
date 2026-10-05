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

/// One condition fact about an identified article — battery 86%, grade A — as
/// the kiosk may show it. Never a cost: the server writes this block by hand.
class PriceLookupUnitAttribute {
  const PriceLookupUnitAttribute({required this.label, required this.value});

  final String label;
  final String value;

  factory PriceLookupUnitAttribute.fromJson(Map<String, Object?> json) {
    final label = json['label']?.toString() ?? '';
    return PriceLookupUnitAttribute(
      label: label.isNotEmpty ? label : json['key']?.toString() ?? '',
      value: json['value']?.toString() ?? '',
    );
  }
}

/// Whether a scanned pack may be sold at all (§6.8.1). Only a scan that named a
/// lot — a lot barcode, a GS1 DataMatrix, a serial inside a lot — can be
/// anything but [ok]; an ordinary barcode always is.
enum PriceLookupAvailability {
  ok,

  /// The lot is quarantined for a recall (or otherwise locked).
  recalled,

  /// The lot is past its date on a product that refuses expired goods.
  expired;

  static PriceLookupAvailability fromJson(Object? value) => switch (value) {
    'recalled' => recalled,
    'expired' => expired,
    _ => ok,
  };
}

/// What staff may know about the lot a scan named, and a kiosk never does:
/// its status, since when it has been stopped, and why. Only present when an
/// authenticated reader holding the lot permission asked for it.
class PriceLookupLotDetail {
  const PriceLookupLotDetail({
    required this.batchId,
    required this.status,
    this.quarantinedAt,
    this.quarantineReason = '',
    this.expiryDate,
  });

  final int batchId;
  final String status;
  final DateTime? quarantinedAt;
  final String quarantineReason;
  final DateTime? expiryDate;

  static PriceLookupLotDetail? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final batchId = json['batch_id'];
    return PriceLookupLotDetail(
      batchId: batchId is int ? batchId : int.tryParse('$batchId') ?? 0,
      status: json['status']?.toString() ?? '',
      quarantinedAt: DateTime.tryParse(
        json['quarantined_at']?.toString() ?? '',
      )?.toLocal(),
      quarantineReason: json['quarantine_reason']?.toString() ?? '',
      expiryDate: DateTime.tryParse(json['expiry_date']?.toString() ?? ''),
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
    this.unitCode = '',
    this.unitAttributes = const [],
    this.availability = PriceLookupAvailability.ok,
    this.lotCode = '',
    this.lotExpiry,
    this.lotDetail,
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

  /// The article a scan named, when it named one — an IMEI read at the kiosk
  /// answers for *that* handset, at its own price, with its own condition.
  final String unitCode;
  final List<PriceLookupUnitAttribute> unitAttributes;

  /// Whether this pack may be sold. Anything but [PriceLookupAvailability.ok]
  /// arrives with no price at all, and the kiosk shows a safety notice.
  final PriceLookupAvailability availability;

  /// The lot code printed on the pack, when the scan named a lot.
  final String lotCode;
  final DateTime? lotExpiry;

  /// Staff-only lot state; null for every kiosk.
  final PriceLookupLotDetail? lotDetail;

  bool get hasImage => imageUrl.isNotEmpty;

  /// A recalled or expired pack: show the safety notice, never a price.
  bool get isStopped => found && availability != PriceLookupAvailability.ok;

  /// A variant name worth showing (non-empty and different from the product).
  bool get showsVariant => variantName.isNotEmpty && variantName != productName;

  factory PriceLookupResult.fromJson(Map<String, Object?> json) {
    final discountsJson = json['discounts'];
    // ``unit`` is the unit of measure's name — except for an identified
    // article, where the server puts the article itself there instead. Read
    // as a string, that block printed as `{code: …}`.
    final unitJson = json['unit'];
    final article = unitJson is Map ? unitJson : const <String, Object?>{};
    final attributesJson = article['attributes'];
    final lotJson = json['lot'];
    final lot = lotJson is Map ? lotJson : const <String, Object?>{};
    return PriceLookupResult(
      found: json['found'] == true,
      barcode: json['barcode']?.toString() ?? '',
      inStock: json['in_stock'] != false,
      currency: json['currency']?.toString() ?? '',
      productName: json['product_name']?.toString() ?? '',
      variantName: json['variant_name']?.toString() ?? '',
      sku: json['sku']?.toString() ?? '',
      unit: unitJson is String ? unitJson : '',
      unitCode: article['code']?.toString() ?? '',
      unitAttributes: attributesJson is List
          ? attributesJson
                .whereType<Map<String, Object?>>()
                .map(PriceLookupUnitAttribute.fromJson)
                .where((attribute) => attribute.value.isNotEmpty)
                .toList(growable: false)
          : const [],
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
      availability: PriceLookupAvailability.fromJson(json['availability']),
      lotCode: lot['code']?.toString() ?? '',
      lotExpiry: DateTime.tryParse(lot['expiry_date']?.toString() ?? ''),
      lotDetail: PriceLookupLotDetail.fromJson(json['lot_detail']),
    );
  }
}
