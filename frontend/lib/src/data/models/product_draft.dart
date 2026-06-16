import 'product_unit.dart';
import 'product_variant_draft.dart';

class ProductDraft {
  const ProductDraft({
    required this.variantSku,
    required this.name,
    required this.variantUnitPrice,
    required this.isActive,
    required this.tracksExpiry,
    this.isService = false,
    this.isPrepared = false,
    this.unit = 'piece',
    this.defaultSaleUnit = '',
    this.defaultPurchaseUnit = '',
    this.units = const [],
    this.variantName = '',
    this.variantBarcode = '',
    this.description = '',
    this.categoryIds = const [],
    this.variantOptionIds = const [],
    this.modifierGroupIds = const [],
    this.optionValueIds = const [],
    this.variants = const [],
  });

  final String variantSku;
  final String name;
  final String variantName;
  final double variantUnitPrice;
  final bool isActive;
  final bool tracksExpiry;
  final bool isService;
  final bool isPrepared;
  final String unit;
  final String defaultSaleUnit;
  final String defaultPurchaseUnit;
  final List<ProductUnit> units;
  final String variantBarcode;
  final String description;
  final List<int> categoryIds;
  final List<int> variantOptionIds;
  final List<int> modifierGroupIds;
  final List<int> optionValueIds;
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
      'units': [for (final unit in units) unit.toJson()],
      'categories': categoryIds,
      'variant_options': variantOptionIds,
      'modifier_groups': modifierGroupIds,
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
