class ProductDraft {
  const ProductDraft({
    required this.sku,
    required this.name,
    required this.unitPrice,
    required this.isActive,
    this.variantName = '',
    this.barcode = '',
    this.description = '',
    this.categoryIds = const [],
    this.optionValueIds = const [],
  });

  final String sku;
  final String name;
  final String variantName;
  final double unitPrice;
  final bool isActive;
  final String barcode;
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
        'sku': sku,
        'barcode': barcode,
        'unit_price': unitPrice.toStringAsFixed(2),
        'is_active': isActive,
        'option_values': optionValueIds,
      },
    };
  }
}
