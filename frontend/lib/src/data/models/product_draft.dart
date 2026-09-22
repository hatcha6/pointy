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
    this.pricingCurrency = '',
    this.variantPriceAmount,
    this.openingQuantity,
    this.openingUnitCost,
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

  /// The currency this product's price sheet is written in; blank means the
  /// shop's own, which is what every product is unless the owner says otherwise.
  final String pricingCurrency;

  /// The default variant's price in [pricingCurrency]. Null when the product is
  /// priced in the shop's own currency — then [variantUnitPrice] is the price.
  final double? variantPriceAmount;

  /// Stock the shop already has of the default variant, and what one unit of it
  /// cost. Create-only: the server opens a valued stock balance so the product
  /// has a real cost from day one instead of waiting for a purchase order.
  /// Ignored when [variants] carries generated rows — those bring their own.
  final double? openingQuantity;
  final double? openingUnitCost;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'description': description,
      'is_active': isActive,
      'tracks_expiry': tracksExpiry,
      'is_service': isService,
      'is_prepared': isPrepared,
      'unit': unit,
      // Sent as null (not omitted) when cleared, so switching a product back to
      // the shop's own currency actually clears it rather than being ignored.
      'pricing_currency': pricingCurrency.isEmpty ? null : pricingCurrency,
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
          if (variantPriceAmount != null)
            'price_amount': variantPriceAmount!.toStringAsFixed(2),
          'is_active': isActive,
          'option_values': optionValueIds,
          if (openingQuantity != null && openingQuantity! > 0) ...{
            'opening_quantity': openingQuantity!.toStringAsFixed(3),
            'opening_unit_cost': (openingUnitCost ?? 0).toStringAsFixed(6),
          },
        }
      else
        'variants': [
          for (final variant in variants) variant.toJson(includeProduct: false),
        ],
    };
  }
}
