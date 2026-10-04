import 'product_tracking.dart';
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
    this.pricingCurrency = '',
    this.tracking,
    this.identifyStockLater = false,
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

  /// The currency this product's price sheet is written in; blank means the
  /// shop's own. Changing it does NOT reprice on its own — the stored base
  /// price stays put until the owner enters a new price or runs a repricing,
  /// because a shelf price must never move as a side effect of a settings edit.
  final String pricingCurrency;

  /// How the product's stock is identified, when the form edited it. Sent in
  /// place of [tracksExpiry], which is then derived from the mode; null keeps
  /// the old single flag, for a save that never showed the choice.
  final ProductTracking? tracking;

  /// The user's yes to the server's question when tracking is turned on over
  /// stock already on the shelf: put that stock on the worklist to be
  /// identified later. Only ever set by [identifyingStockLater], after the
  /// question was shown, so an ordinary save cannot carry a stale answer.
  final bool identifyStockLater;

  /// This same edit, answering the identify-later question with yes.
  ProductUpdateDraft identifyingStockLater() => ProductUpdateDraft(
    name: name,
    description: description,
    isActive: isActive,
    tracksExpiry: tracksExpiry,
    isService: isService,
    isPrepared: isPrepared,
    unit: unit,
    defaultSaleUnit: defaultSaleUnit,
    defaultPurchaseUnit: defaultPurchaseUnit,
    units: units,
    categoryIds: categoryIds,
    variantOptionIds: variantOptionIds,
    modifierGroupIds: modifierGroupIds,
    variants: variants,
    pricingCurrency: pricingCurrency,
    tracking: tracking,
    identifyStockLater: true,
  );

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'description': description,
      'is_active': isActive,
      if (tracking case final tracking?)
        ...tracking.toJson()
      else
        'tracks_expiry': tracksExpiry,
      if (identifyStockLater) 'tracking_mode_identify_later': true,
      'is_service': isService,
      'is_prepared': isPrepared,
      'unit': unit,
      // Explicit null (not omitted) so switching back to the shop's own
      // currency actually clears it rather than being silently ignored.
      'pricing_currency': pricingCurrency.isEmpty ? null : pricingCurrency,
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
