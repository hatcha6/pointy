import 'query.dart';

enum VariantOptionValueAvailabilityFilter implements QueryFilterSet {
  all(null),
  active(QueryFilter(parameter: 'is_active', value: 'true')),
  inactive(QueryFilter(parameter: 'is_active', value: 'false'));

  const VariantOptionValueAvailabilityFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum VariantOptionValueOrdering implements QueryOrdering {
  name('name'),
  displayOrder('display_order'),
  newest('-created_at');

  const VariantOptionValueOrdering(this.apiValue);

  @override
  final String apiValue;
}

class VariantOptionValueQuery extends ModelQuery {
  const VariantOptionValueQuery({
    this.search = '',
    this.availability = VariantOptionValueAvailabilityFilter.all,
    this.ordering = VariantOptionValueOrdering.displayOrder,
    this.optionId,
  });

  @override
  final String search;
  final VariantOptionValueAvailabilityFilter availability;
  @override
  final VariantOptionValueOrdering ordering;
  final int? optionId;

  @override
  Iterable<QueryFilter> get filters => [
    ...availability.filters,
    if (optionId != null) QueryFilter(parameter: 'option', value: '$optionId'),
  ];
}
