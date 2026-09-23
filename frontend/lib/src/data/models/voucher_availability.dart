/// One brand's cards as the provider has them right now — what a card
/// product's picker asks for the moment it opens.
///
/// The picker never waits for it: it opens on the variants the catalog
/// already holds and folds this in when it lands, so a card that sold out
/// since the last sweep disappears while the cashier is still choosing.
library;

double? _toDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

class VoucherCard {
  const VoucherCard({
    required this.variantId,
    required this.label,
    required this.price,
    required this.isAvailable,
    this.cost,
  });

  final int variantId;
  final String label;

  /// What the customer pays — the same figure checkout will charge.
  final double price;

  /// What the agency float pays, for the low-float warning.
  final double? cost;
  final bool isAvailable;

  factory VoucherCard.fromJson(Map<String, Object?> json) {
    return VoucherCard(
      variantId: int.tryParse(json['variant_id']?.toString() ?? '') ?? 0,
      label: json['label']?.toString() ?? '',
      price: _toDouble(json['price']) ?? 0,
      cost: _toDouble(json['cost']),
      isAvailable: json['is_available'] == true,
    );
  }
}

class VoucherAvailability {
  const VoucherAvailability({
    required this.ok,
    this.productId,
    this.cards = const [],
    this.balance,
    this.errorCode = '',
  });

  final bool ok;
  final int? productId;
  final List<VoucherCard> cards;

  /// The agency float as last read, so the picker can warn before a cashier
  /// sells a card the agency cannot pay for.
  final double? balance;
  final String errorCode;

  VoucherCard? cardFor(int variantId) {
    for (final card in cards) {
      if (card.variantId == variantId) return card;
    }
    return null;
  }

  factory VoucherAvailability.fromJson(Map<String, Object?> json) {
    return VoucherAvailability(
      ok: json['ok'] == true,
      productId: int.tryParse(json['product_id']?.toString() ?? ''),
      balance: _toDouble(json['balance']),
      errorCode: json['error_code']?.toString() ?? '',
      cards: (json['cards'] as List<Object?>? ?? const [])
          .whereType<Map<String, Object?>>()
          .map(VoucherCard.fromJson)
          .toList(growable: false),
    );
  }
}
