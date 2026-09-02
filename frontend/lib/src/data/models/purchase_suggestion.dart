/// Why the backend put a product in front of the buyer. The reason is what the
/// chip explains in words — a suggestion nobody can account for is one nobody
/// should act on.
enum PurchaseSuggestionReason {
  /// Bought on the same orders as something already on the draft.
  oftenWith,

  /// Bought from this supplier on a regular rhythm, and the rhythm has come
  /// round again.
  dueAgain,

  /// Simply among the things this shop buys most from this supplier.
  usualForSupplier;

  static PurchaseSuggestionReason fromApi(String? value) {
    return switch (value) {
      'often_with' => PurchaseSuggestionReason.oftenWith,
      'due_again' => PurchaseSuggestionReason.dueAgain,
      _ => PurchaseSuggestionReason.usualForSupplier,
    };
  }
}

/// One suggestion: a product to add, and — only when this shop's own purchase
/// history actually supports one — the quantity and unit to add it in.
///
/// [suggestedQuantity] is null far more often than not, and that is the design:
/// the backend refuses to state a quantity unless the shop has repeated the
/// same one. A chip with no quantity still saves the buyer the lookup.
class PurchaseSuggestion {
  const PurchaseSuggestion({
    required this.variantId,
    required this.productId,
    required this.productName,
    required this.variantName,
    required this.sku,
    required this.reason,
    this.suggestedQuantity,
    this.unitCode = '',
    this.unitFactor = 1,
    this.unitCost,
    this.baseUnitCost,
    this.anchorVariantId,
    this.score = 0,
    this.orderCount = 0,
    this.daysSinceLast,
  });

  final int variantId;
  final int productId;
  final String productName;
  final String variantName;
  final String sku;
  final PurchaseSuggestionReason reason;

  /// In [unitCode], not in base units. Null when the shop's quantities for this
  /// product are not repeatable enough to name one.
  final double? suggestedQuantity;
  final String unitCode;
  final double unitFactor;

  /// Last paid cost expressed in [unitCode] — what the line should start at.
  final double? unitCost;

  /// The same cost per BASE unit. Identical in definition to what the last-cost
  /// endpoint returns, so seeding the view model's cost cache from a suggestion
  /// can never disagree with a value it fetched.
  final double? baseUnitCost;

  /// For [PurchaseSuggestionReason.oftenWith]: the draft line this suggestion
  /// was drawn from, so the chip can say which one.
  final int? anchorVariantId;

  final double score;
  final int orderCount;
  final int? daysSinceLast;

  bool get hasQuantity => (suggestedQuantity ?? 0) > 0;

  String get displayName =>
      variantName.isEmpty ? productName : '$productName — $variantName';

  factory PurchaseSuggestion.fromJson(Map<String, Object?> json) {
    final evidence = json['evidence'];
    final evidenceMap = evidence is Map<String, Object?>
        ? evidence
        : const <String, Object?>{};
    return PurchaseSuggestion(
      variantId: _int(json['variant']),
      productId: _int(json['product']),
      productName: (json['product_name'] as String?) ?? '',
      variantName: (json['variant_name'] as String?) ?? '',
      sku: (json['sku'] as String?) ?? '',
      reason: PurchaseSuggestionReason.fromApi(json['reason'] as String?),
      suggestedQuantity: _doubleOrNull(json['suggested_quantity']),
      unitCode: (json['unit'] as String?) ?? '',
      unitFactor: _doubleOrNull(json['unit_factor']) ?? 1,
      unitCost: _doubleOrNull(json['unit_cost']),
      baseUnitCost: _doubleOrNull(json['base_unit_cost']),
      anchorVariantId: _intOrNull(json['reason_variant']),
      score: _doubleOrNull(json['score']) ?? 0,
      orderCount: _int(evidenceMap['orders']),
      daysSinceLast: _intOrNull(evidenceMap['days_since_last']),
    );
  }
}

/// The shop's recurring order for one supplier — the products that ride on
/// nearly every one of its deliveries. Empty unless the supplier has enough
/// orders behind it for "usual" to mean anything.
class PurchaseUsualBasket {
  const PurchaseUsualBasket({
    this.available = false,
    this.items = const [],
  });

  final bool available;
  final List<PurchaseSuggestion> items;

  int get lineCount => items.length;

  static const PurchaseUsualBasket empty = PurchaseUsualBasket();

  factory PurchaseUsualBasket.fromJson(Map<String, Object?> json) {
    final raw = json['items'];
    final items = raw is List
        ? raw
              .whereType<Map<String, Object?>>()
              .map(PurchaseSuggestion.fromJson)
              .toList(growable: false)
        : const <PurchaseSuggestion>[];
    return PurchaseUsualBasket(
      available: (json['available'] as bool?) ?? false,
      items: items,
    );
  }
}

/// Everything the purchasing screen needs to decorate one draft state.
class PurchaseSuggestionSet {
  const PurchaseSuggestionSet({
    this.enabled = true,
    this.items = const [],
    this.usualBasket = PurchaseUsualBasket.empty,
  });

  /// False when the shop has purchase suggestions switched off. The client
  /// stops asking rather than polling an endpoint that will keep saying no.
  final bool enabled;
  final List<PurchaseSuggestion> items;
  final PurchaseUsualBasket usualBasket;

  bool get isEmpty => items.isEmpty && !usualBasket.available;

  static const PurchaseSuggestionSet empty = PurchaseSuggestionSet();
  static const PurchaseSuggestionSet disabled = PurchaseSuggestionSet(
    enabled: false,
  );

  factory PurchaseSuggestionSet.fromJson(Map<String, Object?> json) {
    final raw = json['items'];
    final basket = json['usual_basket'];
    return PurchaseSuggestionSet(
      enabled: (json['enabled'] as bool?) ?? true,
      items: raw is List
          ? raw
                .whereType<Map<String, Object?>>()
                .map(PurchaseSuggestion.fromJson)
                .toList(growable: false)
          : const <PurchaseSuggestion>[],
      usualBasket: basket is Map<String, Object?>
          ? PurchaseUsualBasket.fromJson(basket)
          : PurchaseUsualBasket.empty,
    );
  }
}

/// Tolerant number readers: DRF renders decimals as strings ("6.000") and ints
/// as numbers, and a rebuilt row can carry nulls, so every field is parsed
/// through its string form rather than cast.
int _int(Object? value) => _intOrNull(value) ?? 0;

int? _intOrNull(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  return int.tryParse(value.toString()) ??
      double.tryParse(value.toString())?.round();
}

double? _doubleOrNull(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value.toString());
}
