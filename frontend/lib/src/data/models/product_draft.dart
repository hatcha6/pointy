class ProductDraft {
  const ProductDraft({
    required this.sku,
    required this.name,
    required this.unitPrice,
    required this.isActive,
    this.barcode = '',
    this.description = '',
    this.categoryIds = const [],
  });

  final String sku;
  final String name;
  final double unitPrice;
  final bool isActive;
  final String barcode;
  final String description;
  final List<int> categoryIds;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'description': description,
      'is_active': isActive,
      'categories': categoryIds,
      'default_variant': {
        'sku': sku,
        'barcode': barcode,
        'unit_price': unitPrice.toStringAsFixed(2),
        'is_active': isActive,
      },
    };
  }
}
