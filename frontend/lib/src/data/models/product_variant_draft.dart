class ProductVariantDraft {
  const ProductVariantDraft({
    required this.productId,
    required this.sku,
    required this.unitPrice,
    this.name = '',
    this.barcode = '',
    this.isActive = true,
    this.isDefault = false,
    this.optionValueIds = const [],
  });

  final int productId;
  final String name;
  final String sku;
  final String barcode;
  final double unitPrice;
  final bool isActive;
  final bool isDefault;
  final List<int> optionValueIds;

  Map<String, Object?> toJson({bool includeProduct = true}) {
    return {
      if (includeProduct) 'product': productId,
      'name': name,
      'sku': sku,
      'barcode': barcode,
      'unit_price': unitPrice.toStringAsFixed(2),
      'is_active': isActive,
      'is_default': isDefault,
      'option_values': optionValueIds,
    };
  }
}
