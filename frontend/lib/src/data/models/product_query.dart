import 'query.dart';

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
    this.availability = ProductAvailabilityFilter.all,
    this.ordering = ProductOrdering.name,
  });

  @override
  final String search;
  final String barcode;
  final ProductAvailabilityFilter availability;
  @override
  final ProductOrdering ordering;

  @override
  Iterable<QueryFilter> get filters => [
    ...availability.filters,
    if (barcode.trim().isNotEmpty)
      QueryFilter(parameter: 'barcode', value: barcode.trim()),
  ];

  ProductQuery copyWith({
    String? search,
    String? barcode,
    ProductAvailabilityFilter? availability,
    ProductOrdering? ordering,
  }) {
    return ProductQuery(
      search: search ?? this.search,
      barcode: barcode ?? this.barcode,
      availability: availability ?? this.availability,
      ordering: ordering ?? this.ordering,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ProductQuery &&
        other.search == search &&
        other.barcode == barcode &&
        other.availability == availability &&
        other.ordering == ordering;
  }

  @override
  int get hashCode => Object.hash(search, barcode, availability, ordering);
}
