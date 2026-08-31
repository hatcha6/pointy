class ProductVariantDraft {
  const ProductVariantDraft({
    required this.productId,
    required this.sku,
    required this.unitPrice,
    this.id,
    this.name = '',
    this.barcode = '',
    this.isActive = true,
    this.isDefault = false,
    this.optionValueIds = const [],
    this.priceAmount,
  });

  final int? id;
  final int productId;
  final String name;
  final String sku;
  final String barcode;
  final double unitPrice;
  final bool isActive;
  final bool isDefault;
  final List<int> optionValueIds;

  /// The price as written in the product's pricing currency, when it has one.
  /// Sending it makes the server *derive* [unitPrice]; the two are never sent
  /// as independent numbers, so they cannot disagree.
  final double? priceAmount;

  Map<String, Object?> toJson({bool includeProduct = true}) {
    return {
      if (id != null) 'id': id,
      if (includeProduct) 'product': productId,
      'name': name,
      'sku': sku,
      'barcode': barcode,
      'unit_price': unitPrice.toStringAsFixed(2),
      if (priceAmount != null) 'price_amount': priceAmount!.toStringAsFixed(2),
      'is_active': isActive,
      'is_default': isDefault,
      'option_values': optionValueIds,
    };
  }
}
