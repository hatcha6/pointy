import '../../../data/models/product.dart';
import '../../../data/models/product_unit.dart';
import '../../../data/models/product_variant.dart';
import '../../../shared/product_category_picker.dart';
import 'product_entry_run.dart';
import 'variant_generation.dart';

/// One variant of the product being copied, as the matching row of the new
/// product's generated grid starts out.
typedef SimilarVariantRow = ({String price, bool isActive});

/// What a «منتج مشابه» starts from: everything that describes the source
/// product and nothing that identifies it.
///
/// A barcode or SKU belongs to one product, so the copy is numbered like any
/// new product and scanned for its own code. A picture shows the source, not
/// the copy. Stock is counted, never copied. Packaging units come along, since
/// a similar product is boxed the same way, but their barcodes do not.
class SimilarProduct {
  const SimilarProduct._({
    required this.sourceName,
    required this.carried,
    required this.description,
    required this.isService,
    required this.isPrepared,
    required this.modifierGroupIds,
    required this.units,
    required this.defaultSaleUnit,
    required this.defaultPurchaseUnit,
    required this.variantOptionIds,
    required this.valueIdsByOption,
    required this.rowsBySignature,
    required this.defaultSignature,
  });

  factory SimilarProduct.of(Product source) {
    final isForeignPriced = source.pricingCurrency.isNotEmpty;
    String priceOf(ProductVariant variant) {
      final amount = isForeignPriced ? variant.priceAmount : variant.unitPrice;
      return amount == null ? '' : _editableAmount(amount);
    }

    final defaultVariant = source.defaultVariant;
    final defaultPrice = defaultVariant == null ? '' : priceOf(defaultVariant);
    final variants = [
      ...source.variants,
      if (defaultVariant != null &&
          !source.variants.any((variant) => variant.id == defaultVariant.id))
        defaultVariant,
    ];

    final declaredOptionIds = {
      for (final option in source.variantOptions) option.id,
    };
    final optionOfValue = <int, int>{
      for (final option in source.variantOptions)
        for (final value in option.values) value.id: option.id,
      for (final variant in variants)
        for (final value in variant.optionValues) value.id: value.optionId,
    };
    final valueIdsByOption = <int, Set<int>>{};
    final rowsBySignature = <String, SimilarVariantRow>{};
    String? defaultSignature;
    if (declaredOptionIds.isNotEmpty) {
      for (final variant in variants) {
        if (variant.optionValueIds.isEmpty) {
          continue;
        }
        for (final valueId in variant.optionValueIds) {
          final optionId = optionOfValue[valueId];
          if (optionId != null && declaredOptionIds.contains(optionId)) {
            valueIdsByOption.putIfAbsent(optionId, () => {}).add(valueId);
          }
        }
        final signature = variantSignature(variant.optionValueIds);
        rowsBySignature[signature] = (
          price: priceOf(variant),
          isActive: variant.isActive,
        );
        if (variant.isDefault || variant.id == defaultVariant?.id) {
          defaultSignature = signature;
        }
      }
    }

    return SimilarProduct._(
      sourceName: source.name,
      carried: ProductCarryOverValues(
        name: source.name,
        price: defaultPrice,
        // A price is copied in the currency it was written in, or not at all.
        pricingCurrency: defaultPrice.isEmpty ? '' : source.pricingCurrency,
        categories: [
          for (final category in source.categories)
            productCategoryOption(category),
        ],
        unit: source.unit,
        tracksExpiry: source.tracksExpiry,
        // An opening cost is what the source's own shelf was bought at.
        openingCost: '',
      ),
      description: source.description,
      isService: source.isService,
      isPrepared: source.isPrepared,
      modifierGroupIds: {for (final group in source.modifierGroups) group.id},
      units: [
        for (final unit in source.units)
          ProductUnit(
            unit: unit.unit,
            factorToBase: unit.factorToBase,
            price: unit.price,
            isSellable: unit.isSellable,
            isPurchasable: unit.isPurchasable,
            displayOrder: unit.displayOrder,
          ),
      ],
      defaultSaleUnit: source.defaultSaleUnit,
      defaultPurchaseUnit: source.defaultPurchaseUnit,
      // Only options with values to copy: an option selected with none would
      // leave the new product's grid empty.
      variantOptionIds: valueIdsByOption.keys.toSet(),
      valueIdsByOption: valueIdsByOption,
      rowsBySignature: rowsBySignature,
      defaultSignature: defaultSignature,
    );
  }

  final String sourceName;

  /// The values a run of products could carry, filled in from the source.
  final ProductCarryOverValues carried;
  final String description;
  final bool isService;
  final bool isPrepared;
  final Set<int> modifierGroupIds;

  /// The source's packaging units, as new rows: no ids, no barcodes.
  final List<ProductUnit> units;
  final String defaultSaleUnit;
  final String defaultPurchaseUnit;

  /// The options the source's variants are made of, and which of each
  /// option's values it uses — its grid of sizes and colours.
  final Set<int> variantOptionIds;
  final Map<int, Set<int>> valueIdsByOption;

  /// The source's variants, keyed by [variantSignature] of their values.
  final Map<String, SimilarVariantRow> rowsBySignature;
  final String? defaultSignature;

  bool get hasVariantGrid => variantOptionIds.isNotEmpty;

  /// Whether something copied sits in the folded «تفاصيل إضافية», which then
  /// opens: a copied value should never be out of sight.
  bool get fillsMoreDetails =>
      description.isNotEmpty ||
      isService ||
      isPrepared ||
      modifierGroupIds.isNotEmpty;
}

/// An amount as an input shows it: exact, without trailing zeros. A dinar
/// price can have three decimal places, so rounding to two would copy a
/// different price.
String _editableAmount(double value) => value
    .toStringAsFixed(6)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');
