import 'product.dart';

class ProductPage {
  const ProductPage({required this.products, required this.hasMore});

  final List<Product> products;
  final bool hasMore;

  factory ProductPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(Product.fromJson)
        .toList(growable: false);

    return ProductPage(products: results, hasMore: json['next'] != null);
  }
}

class ProductVariantPage {
  const ProductVariantPage({required this.variants, required this.hasMore});

  final List<ProductVariant> variants;
  final bool hasMore;

  factory ProductVariantPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(ProductVariant.fromJson)
        .toList(growable: false);

    return ProductVariantPage(variants: results, hasMore: json['next'] != null);
  }
}
