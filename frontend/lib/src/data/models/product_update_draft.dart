import 'product_unit.dart';
import 'product_variant_draft.dart';

class ProductUpdateDraft {
  const ProductUpdateDraft({
    required this.name,
    required this.description,
    required this.isActive,
    required this.tracksExpiry,
    this.isService = false,
    this.isPrepared = false,
    this.unit = 'piece',
    this.defaultSaleUnit = '',
    this.defaultPurchaseUnit = '',
    this.units,
    required this.categoryIds,
    this.variantOptionIds,
    this.modifierGroupIds,
    this.variants = const [],
  });

  final String name;
  final String description;
  final bool isActive;
  final bool tracksExpiry;
  final bool isService;
  final bool isPrepared;
  final String unit;
  final String defaultSaleUnit;
  final String defaultPurchaseUnit;
  final List<ProductUnit>? units;
  final List<int> categoryIds;
  final List<int>? variantOptionIds;
  final List<int>? modifierGroupIds;
  final List<ProductVariantDraft> variants;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'description': description,
      'is_active': isActive,
      'tracks_expiry': tracksExpiry,
      'is_service': isService,
      'is_prepared': isPrepared,
      'unit': unit,
      'default_sale_unit': defaultSaleUnit,
      'default_purchase_unit': defaultPurchaseUnit,
      if (units != null) 'units': [for (final unit in units!) unit.toJson()],
      'categories': categoryIds,
      if (variantOptionIds != null) 'variant_options': variantOptionIds,
      if (modifierGroupIds != null) 'modifier_groups': modifierGroupIds,
      if (variants.isNotEmpty)
        'variants': [
          for (final variant in variants) variant.toJson(includeProduct: false),
        ],
    };
  }
}
