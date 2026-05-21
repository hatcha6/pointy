import 'product_category.dart';
import 'product_variant.dart';

class Product {
  const Product({
    required this.id,
    required this.name,
    required this.quantityOnHand,
    this.sku = '',
    this.unitPrice = 0,
    this.barcode = '',
    this.description = '',
    this.isActive = true,
    this.categories = const [],
    this.defaultVariant,
    this.variants = const [],
  });

  final int id;
  final String name;
  final int quantityOnHand;
  final String sku;
  final double unitPrice;
  final String barcode;
  final String description;
  final bool isActive;
  final List<ProductCategory> categories;
  final ProductVariant? defaultVariant;
  final List<ProductVariant> variants;

  int get variantId => defaultVariant?.id ?? id;

  String get sellableName {
    final variantName = defaultVariant?.displayLabel;
    if (variantName != null && variantName.isNotEmpty) {
      return variantName;
    }
    return name;
  }

  String get effectiveSku => defaultVariant?.sku ?? sku;

  String get effectiveBarcode => defaultVariant?.barcode ?? barcode;

  double get effectiveUnitPrice => defaultVariant?.unitPrice ?? unitPrice;

  int get effectiveQuantityOnHand =>
      defaultVariant?.quantityOnHand ?? quantityOnHand;

  List<ProductVariant> get activeVariants {
    if (!isActive) {
      return const [];
    }
    final active = <ProductVariant>[];
    final seen = <int>{};
    for (final variant in variants) {
      if (variant.isActive && seen.add(variant.id)) {
        active.add(variant);
      }
    }
    final defaultVariant = this.defaultVariant;
    if (defaultVariant != null &&
        defaultVariant.isActive &&
        seen.add(defaultVariant.id)) {
      active.insert(0, defaultVariant);
    }
    active.sort((a, b) {
      if (a.isDefault != b.isDefault) {
        return a.isDefault ? -1 : 1;
      }
      return a.pickerLabel.compareTo(b.pickerLabel);
    });
    return active;
  }

  factory Product.fromJson(Map<String, Object?> json) {
    final defaultVariantJson = json['default_variant'];
    final defaultVariant = defaultVariantJson is Map<String, Object?>
        ? ProductVariant.fromJson(defaultVariantJson)
        : null;
    final variants = _variantsFromJson(json);
    return Product(
      id: _intFromJson(json['id']),
      sku: json['sku']?.toString() ?? defaultVariant?.sku ?? '',
      name: json['name']?.toString() ?? '',
      unitPrice: _moneyFromJson(
        json['unit_price'] ?? defaultVariant?.unitPrice,
      ),
      quantityOnHand: _intFromJson(
        json['quantity_on_hand'] ?? defaultVariant?.quantityOnHand,
      ),
      barcode: json['barcode']?.toString() ?? defaultVariant?.barcode ?? '',
      description: (json['description'] as String?) ?? '',
      isActive: (json['is_active'] as bool?) ?? true,
      categories: _categoriesFromJson(json),
      defaultVariant: defaultVariant,
      variants: variants,
    );
  }

  factory Product.fromVariant(ProductVariant variant) {
    final detail = variant.productDetail;
    return Product(
      id: variant.productId,
      sku: variant.sku,
      name: variant.displayLabel.isNotEmpty
          ? variant.displayLabel
          : detail?.name ?? variant.productName,
      unitPrice: variant.unitPrice,
      quantityOnHand: variant.quantityOnHand,
      barcode: variant.barcode,
      description: detail?.description ?? '',
      isActive: variant.isSellable,
      categories: detail?.categories ?? const [],
      defaultVariant: variant,
    );
  }

  Product copyWith({
    int? quantityOnHand,
    ProductVariant? defaultVariant,
    List<ProductVariant>? variants,
  }) {
    final nextDefaultVariant =
        defaultVariant ??
        (quantityOnHand == null
            ? this.defaultVariant
            : this.defaultVariant?.copyWith(quantityOnHand: quantityOnHand));
    return Product(
      id: id,
      sku: sku,
      name: name,
      unitPrice: unitPrice,
      quantityOnHand: quantityOnHand ?? this.quantityOnHand,
      barcode: barcode,
      description: description,
      isActive: isActive,
      categories: categories,
      defaultVariant: nextDefaultVariant,
      variants: variants ?? this.variants,
    );
  }

  static List<ProductCategory> _categoriesFromJson(Map<String, Object?> json) {
    final details = json['category_details'];
    if (details is List<Object?>) {
      return details
          .cast<Map<String, Object?>>()
          .map(ProductCategory.fromJson)
          .toList(growable: false);
    }
    final categoryIds = json['categories'];
    if (categoryIds is List<Object?>) {
      return [
        for (final id in categoryIds)
          if (id is num) ProductCategory(id: id.toInt(), name: ''),
      ];
    }
    return const [];
  }

  static List<ProductVariant> _variantsFromJson(Map<String, Object?> json) {
    final variants = json['variants'];
    if (variants is List<Object?>) {
      return variants
          .whereType<Map<String, Object?>>()
          .map(ProductVariant.fromJson)
          .toList(growable: false);
    }
    return const [];
  }
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}

double _moneyFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse((value ?? 0).toString()) ?? 0;
}
