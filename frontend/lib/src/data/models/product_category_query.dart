import 'query.dart';

enum ProductCategoryAvailabilityFilter implements QueryFilterSet {
  all(null),
  active(QueryFilter(parameter: 'is_active', value: 'true')),
  inactive(QueryFilter(parameter: 'is_active', value: 'false'));

  const ProductCategoryAvailabilityFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum ProductCategoryOrdering implements QueryOrdering {
  name('name'),
  newest('-created_at');

  const ProductCategoryOrdering(this.apiValue);

  @override
  final String apiValue;
}

class ProductCategoryQuery extends ModelQuery {
  const ProductCategoryQuery({
    this.search = '',
    this.availability = ProductCategoryAvailabilityFilter.all,
    this.ordering = ProductCategoryOrdering.name,
  });

  @override
  final String search;
  final ProductCategoryAvailabilityFilter availability;
  @override
  final ProductCategoryOrdering ordering;

  @override
  Iterable<QueryFilter> get filters => availability.filters;
}
