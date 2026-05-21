import 'product_category.dart';

class ProductVariant {
  const ProductVariant({
    required this.id,
    required this.productId,
    required this.sku,
    required this.unitPrice,
    this.productName = '',
    this.productDetail,
    this.name = '',
    this.displayName = '',
    this.fullName = '',
    this.barcode = '',
    this.isActive = true,
    this.isDefault = false,
    this.quantityOnHand = 0,
    this.optionValueIds = const [],
  });

  final int id;
  final int productId;
  final String productName;
  final Product? productDetail;
  final String name;
  final String displayName;
  final String fullName;
  final String sku;
  final String barcode;
  final double unitPrice;
  final bool isActive;
  final bool isDefault;
  final int quantityOnHand;
  final List<int> optionValueIds;

  factory ProductVariant.fromJson(Map<String, Object?> json) {
    final productDetailJson = json['product_detail'];
    final productDetail = productDetailJson is Map<String, Object?>
        ? Product.fromJson(productDetailJson)
        : null;
    return ProductVariant(
      id: _intFromJson(json['id']),
      productId: _productIdFromJson(json['product']) ?? productDetail?.id ?? 0,
      productName:
          json['product_name']?.toString() ?? productDetail?.name ?? '',
      productDetail: productDetail,
      name: json['name']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      fullName: json['full_name']?.toString() ?? '',
      sku: json['sku']?.toString() ?? '',
      barcode: json['barcode']?.toString() ?? '',
      unitPrice: _moneyFromJson(json['unit_price']),
      isActive: _boolFromJson(json['is_active'], fallback: true),
      isDefault: _boolFromJson(json['is_default']),
      quantityOnHand: _intFromJson(json['quantity_on_hand']),
      optionValueIds: _intListFromJson(json['option_values']),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'product': productId,
      'name': name,
      'sku': sku,
      'barcode': barcode,
      'unit_price': unitPrice.toStringAsFixed(2),
      'is_active': isActive,
      'is_default': isDefault,
      'option_values': optionValueIds,
    };
  }

  ProductVariant copyWith({int? quantityOnHand}) {
    return ProductVariant(
      id: id,
      productId: productId,
      productName: productName,
      productDetail: productDetail,
      name: name,
      displayName: displayName,
      fullName: fullName,
      sku: sku,
      barcode: barcode,
      unitPrice: unitPrice,
      isActive: isActive,
      isDefault: isDefault,
      quantityOnHand: quantityOnHand ?? this.quantityOnHand,
      optionValueIds: optionValueIds,
    );
  }
}

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

  int get sellableId => variantId;

  String get sellableName {
    final variantName = defaultVariant?.fullName;
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
      name: variant.fullName.isNotEmpty
          ? variant.fullName
          : detail?.name ?? variant.productName,
      unitPrice: variant.unitPrice,
      quantityOnHand: variant.quantityOnHand,
      barcode: variant.barcode,
      description: detail?.description ?? '',
      isActive: variant.isActive && (detail?.isActive ?? true),
      categories: detail?.categories ?? const [],
      defaultVariant: variant,
    );
  }

  Product copyWith({int? quantityOnHand}) {
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
      defaultVariant: quantityOnHand == null
          ? defaultVariant
          : defaultVariant?.copyWith(quantityOnHand: quantityOnHand),
      variants: variants,
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

class ProductDraft {
  const ProductDraft({
    required this.sku,
    required this.name,
    required this.unitPrice,
    required this.isActive,
    this.barcode = '',
    this.description = '',
    this.categoryIds = const [],
  });

  final String sku;
  final String name;
  final double unitPrice;
  final bool isActive;
  final String barcode;
  final String description;
  final List<int> categoryIds;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'description': description,
      'is_active': isActive,
      'categories': categoryIds,
      'default_variant': {
        'sku': sku,
        'barcode': barcode,
        'unit_price': unitPrice.toStringAsFixed(2),
        'is_active': isActive,
      },
    };
  }
}

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

int? _productIdFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is Map<String, Object?>) {
    return _intFromJson(value['id']);
  }
  if (value == null) {
    return null;
  }
  return int.tryParse(value.toString());
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

bool _boolFromJson(Object? value, {bool fallback = false}) {
  if (value is bool) {
    return value;
  }
  if (value == null) {
    return fallback;
  }
  return value.toString() == 'true';
}

List<int> _intListFromJson(Object? value) {
  if (value is List<Object?>) {
    final ids = <int>[];
    for (final item in value) {
      final id = _productIdFromJson(item);
      if (id != null) {
        ids.add(id);
      }
    }
    return ids;
  }
  return const [];
}
