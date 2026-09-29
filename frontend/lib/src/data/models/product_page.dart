import 'product.dart';
import 'product_search_outcome.dart';

class ProductPage {
  const ProductPage({
    required this.products,
    required this.hasMore,
    this.searchOutcome,
  });

  final List<Product> products;
  final bool hasMore;

  /// How a search found this page; null for a browse.
  final ProductSearchOutcome? searchOutcome;

  factory ProductPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(Product.fromJson)
        .toList(growable: false);

    return ProductPage(
      products: results,
      hasMore: json['next'] != null,
      searchOutcome: ProductSearchOutcome.fromJson(json['search']),
    );
  }
}
