import 'query.dart';
import 'product_category.dart';

enum ProductAvailabilityFilter implements QueryFilterSet {
  all(null),
  active(QueryFilter(parameter: 'is_active', value: 'true')),
  inactive(QueryFilter(parameter: 'is_active', value: 'false'));

  const ProductAvailabilityFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum ProductOrdering implements QueryOrdering {
  name('name'),
  priceAsc('unit_price'),
  priceDesc('-unit_price'),
  newest('-created_at');

  const ProductOrdering(this.apiValue);

  @override
  final String apiValue;
}

class ProductQuery extends ModelQuery {
  const ProductQuery({
    this.search = '',
    this.barcode = '',
    this.categories = const [],
    this.availability = ProductAvailabilityFilter.all,
    this.ordering = ProductOrdering.name,
  });

  @override
  final String search;
  final String barcode;
  final List<ProductCategory> categories;
  final ProductAvailabilityFilter availability;
  @override
  final ProductOrdering ordering;

  @override
  Iterable<QueryFilter> get filters => [
    ...availability.filters,
    if (barcode.trim().isNotEmpty)
      QueryFilter(parameter: 'barcode', value: barcode.trim()),
    if (categories.isNotEmpty)
      QueryFilter(
        parameter: 'category',
        value: categories.map((category) => category.id).join(','),
      ),
  ];

  ProductQuery copyWith({
    String? search,
    String? barcode,
    List<ProductCategory>? categories,
    ProductAvailabilityFilter? availability,
    ProductOrdering? ordering,
  }) {
    return ProductQuery(
      search: search ?? this.search,
      barcode: barcode ?? this.barcode,
      categories: categories ?? this.categories,
      availability: availability ?? this.availability,
      ordering: ordering ?? this.ordering,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ProductQuery &&
        other.search == search &&
        other.barcode == barcode &&
        _sameCategoryIds(other.categories, categories) &&
        other.availability == availability &&
        other.ordering == ordering;
  }

  @override
  int get hashCode => Object.hash(
    search,
    barcode,
    Object.hashAll(categories.map((category) => category.id)),
    availability,
    ordering,
  );

  static bool _sameCategoryIds(
    List<ProductCategory> first,
    List<ProductCategory> second,
  ) {
    if (first.length != second.length) {
      return false;
    }
    for (var index = 0; index < first.length; index += 1) {
      if (first[index].id != second[index].id) {
        return false;
      }
    }
    return true;
  }
}
