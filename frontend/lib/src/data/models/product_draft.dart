import 'product_variant_draft.dart';

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
    this.variantOptionIds = const [],
    this.optionValueIds = const [],
    this.variants = const [],
  });

  final String variantSku;
  final String name;
  final String variantName;
  final double variantUnitPrice;
  final bool isActive;
  final String variantBarcode;
  final String description;
  final List<int> categoryIds;
  final List<int> variantOptionIds;
  final List<int> optionValueIds;
  final List<ProductVariantDraft> variants;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'description': description,
      'is_active': isActive,
      'categories': categoryIds,
      'variant_options': variantOptionIds,
      if (variants.isEmpty)
        'default_variant': {
          'name': variantName,
          'sku': variantSku,
          'barcode': variantBarcode,
          'unit_price': variantUnitPrice.toStringAsFixed(2),
          'is_active': isActive,
          'option_values': optionValueIds,
        }
      else
        'variants': [
          for (final variant in variants) variant.toJson(includeProduct: false),
        ],
    };
  }
}
