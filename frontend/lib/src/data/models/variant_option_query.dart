import 'query.dart';

enum VariantOptionAvailabilityFilter implements QueryFilterSet {
  all(null),
  active(QueryFilter(parameter: 'is_active', value: 'true')),
  inactive(QueryFilter(parameter: 'is_active', value: 'false'));

  const VariantOptionAvailabilityFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum VariantOptionOrdering implements QueryOrdering {
  name('name'),
  displayOrder('display_order'),
  newest('-created_at');

  const VariantOptionOrdering(this.apiValue);

  @override
  final String apiValue;
}

class VariantOptionQuery extends ModelQuery {
  const VariantOptionQuery({
    this.search = '',
    this.availability = VariantOptionAvailabilityFilter.all,
    this.ordering = VariantOptionOrdering.displayOrder,
  });

  @override
  final String search;
  final VariantOptionAvailabilityFilter availability;
  @override
  final VariantOptionOrdering ordering;

  @override
  Iterable<QueryFilter> get filters => availability.filters;
}
