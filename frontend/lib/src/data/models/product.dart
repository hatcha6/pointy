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
  });

  final int id;
  final String sku;
  final String name;
  final double unitPrice;
  final int quantityOnHand;
  final String barcode;
  final String description;
  final bool isActive;

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
