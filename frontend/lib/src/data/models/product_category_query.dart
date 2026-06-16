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
  /// Manual sort order (the quick-access strip and the management tree).
  manual('display_order'),
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
    this.parentId,
    this.rootOnly = false,
    this.quickAccessOnly = false,
  });

  @override
  final String search;
  final ProductCategoryAvailabilityFilter availability;
  @override
  final ProductCategoryOrdering ordering;
  final int? parentId;
  final bool rootOnly;
  final bool quickAccessOnly;

  @override
  Iterable<QueryFilter> get filters => [
    ...availability.filters,
    if (quickAccessOnly)
      const QueryFilter(parameter: 'is_quick_access', value: 'true'),
    if (parentId != null)
      QueryFilter(parameter: 'parent', value: '$parentId')
    else if (rootOnly)
      const QueryFilter(parameter: 'root', value: 'true'),
  ];
}
