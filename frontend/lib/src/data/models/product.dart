class Product {
  const Product({
    required this.id,
    required this.sku,
    required this.name,
    required this.unitPrice,
    required this.taxRate,
    this.barcode = '',
  });

  final int id;
  final String sku;
  final String name;
  final double unitPrice;
  final double taxRate;
  final String barcode;

  factory Product.fromJson(Map<String, Object?> json) {
    return Product(
      id: json['id'] as int,
      sku: json['sku'] as String,
      name: json['name'] as String,
      unitPrice: double.parse(json['unit_price'].toString()),
      taxRate: double.parse(json['tax_rate'].toString()),
      barcode: (json['barcode'] as String?) ?? '',
    );
  }
}
