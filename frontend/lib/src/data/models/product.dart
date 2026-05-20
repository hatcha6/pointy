import 'product_category.dart';

class Product {
  const Product({
    required this.id,
    required this.sku,
    required this.name,
    required this.unitPrice,
    required this.quantityOnHand,
    this.barcode = '',
    this.description = '',
    this.isActive = true,
    this.categories = const [],
  });

  final int id;
  final String sku;
  final String name;
  final double unitPrice;
  final int quantityOnHand;
  final String barcode;
  final String description;
  final bool isActive;
  final List<ProductCategory> categories;

  factory Product.fromJson(Map<String, Object?> json) {
    return Product(
      id: json['id'] as int,
      sku: json['sku'] as String,
      name: json['name'] as String,
      unitPrice: double.parse(json['unit_price'].toString()),
      quantityOnHand: (json['quantity_on_hand'] as num?)?.toInt() ?? 0,
      barcode: (json['barcode'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      isActive: (json['is_active'] as bool?) ?? true,
      categories: _categoriesFromJson(json),
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
      'sku': sku,
      'barcode': barcode,
      'name': name,
      'description': description,
      'unit_price': unitPrice.toStringAsFixed(2),
      'is_active': isActive,
      'categories': categoryIds,
    };
  }
}
