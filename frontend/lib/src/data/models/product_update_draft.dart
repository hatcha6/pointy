import 'product_variant_draft.dart';

class ProductUpdateDraft {
  const ProductUpdateDraft({
    required this.name,
    required this.description,
    required this.isActive,
    required this.categoryIds,
    this.variantOptionIds,
    this.variants = const [],
  });

  final String name;
  final String description;
  final bool isActive;
  final List<int> categoryIds;
  final List<int>? variantOptionIds;
  final List<ProductVariantDraft> variants;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'description': description,
      'is_active': isActive,
      'categories': categoryIds,
      if (variantOptionIds != null) 'variant_options': variantOptionIds,
      if (variants.isNotEmpty)
        'variants': [
          for (final variant in variants) variant.toJson(includeProduct: false),
        ],
    };
  }
}
