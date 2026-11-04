class ProductVariantDraft {
  const ProductVariantDraft({
    required this.productId,
    required this.sku,
    required this.unitPrice,
    this.id,
    this.name = '',
    this.barcode = '',
    this.extraBarcodes,
    this.gtin,
    this.isActive = true,
    this.isDefault = false,
    this.optionValueIds = const [],
    this.priceAmount,
    this.openingQuantity,
    this.openingUnitCost,
    this.lowStockThreshold,
  });

  final int? id;
  final int productId;
  final String name;
  final String sku;
  final String barcode;

  /// The variant's further barcodes. Null leaves the saved ones alone (a form
  /// that does not show them must not wipe them); a list replaces them.
  final List<String>? extraBarcodes;

  /// The GS1 trade-item number as typed. Null leaves the saved one alone —
  /// the editor only shows the field where it matters — and blank clears it.
  final String? gtin;
  final double unitPrice;
  final bool isActive;
  final bool isDefault;
  final List<int> optionValueIds;

  /// The price as written in the product's pricing currency, when it has one.
  /// Sending it makes the server *derive* [unitPrice]; the two are never sent
  /// as independent numbers, so they cannot disagree.
  final double? priceAmount;

  /// Stock the shop already has of this variant, and what one unit of it cost.
  /// Accepted only when the product is created — the server opens a valued
  /// stock balance and refuses the pair on an edit. Both are per base unit,
  /// like [unitPrice] beside them.
  final double? openingQuantity;
  final double? openingUnitCost;

  /// The low-stock threshold to write, wrapped so "leave it" and "clear it"
  /// differ: null sends nothing and the saved one stays (a form that does not
  /// show the field must not wipe it); `(value: null)` clears it — the variant
  /// stops being watched; `(value: n)` sets it.
  final ({double? value})? lowStockThreshold;

  Map<String, Object?> toJson({bool includeProduct = true}) {
    return {
      if (id != null) 'id': id,
      if (includeProduct) 'product': productId,
      'name': name,
      'sku': sku,
      'barcode': barcode,
      if (extraBarcodes != null) 'extra_barcodes': extraBarcodes,
      if (gtin != null) 'gtin': gtin,
      'unit_price': unitPrice.toStringAsFixed(2),
      if (priceAmount != null) 'price_amount': priceAmount!.toStringAsFixed(2),
      'is_active': isActive,
      'is_default': isDefault,
      'option_values': optionValueIds,
      if (lowStockThreshold case (:final value))
        'low_stock_threshold': value?.toStringAsFixed(3),
      if (openingQuantity != null && openingQuantity! > 0) ...{
        'opening_quantity': openingQuantity!.toStringAsFixed(3),
        'opening_unit_cost': (openingUnitCost ?? 0).toStringAsFixed(6),
      },
    };
  }
}
