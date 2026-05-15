class Product {
  const Product({
    required this.id,
    required this.sku,
    required this.name,
    required this.unitPrice,
    this.barcode = '',
    this.description = '',
    this.isActive = true,
  });

  final int id;
  final String sku;
  final String name;
  final double unitPrice;
  final String barcode;
  final String description;
  final bool isActive;

  factory Product.fromJson(Map<String, Object?> json) {
    return Product(
      id: json['id'] as int,
      sku: json['sku'] as String,
      name: json['name'] as String,
      unitPrice: double.parse(json['unit_price'].toString()),
      barcode: (json['barcode'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      isActive: (json['is_active'] as bool?) ?? true,
    );
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
  });

  final String sku;
  final String name;
  final double unitPrice;
  final bool isActive;
  final String barcode;
  final String description;

  Map<String, Object?> toJson() {
    return {
      'sku': sku,
      'barcode': barcode,
      'name': name,
      'description': description,
      'unit_price': unitPrice.toStringAsFixed(2),
      'is_active': isActive,
    };
  }
}
