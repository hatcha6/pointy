class ProductDraft {
  const ProductDraft({
    required this.variantSku,
    required this.name,
    required this.variantUnitPrice,
    required this.isActive,
    this.variantName = '',
    this.variantBarcode = '',
    this.description = '',
    this.categoryIds = const [],
    this.optionValueIds = const [],
  });

  final String variantSku;
  final String name;
  final String variantName;
  final double variantUnitPrice;
  final bool isActive;
  final String variantBarcode;
  final String description;
  final List<int> categoryIds;
  final List<int> optionValueIds;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'description': description,
      'is_active': isActive,
      'categories': categoryIds,
      'default_variant': {
        'name': variantName,
        'sku': variantSku,
        'barcode': variantBarcode,
        'unit_price': variantUnitPrice.toStringAsFixed(2),
        'is_active': isActive,
        'option_values': optionValueIds,
      },
    };
  }
}
