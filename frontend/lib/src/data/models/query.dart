abstract class ModelQuery {
  const ModelQuery();

  String get search;
  QueryOrdering get ordering;
  Iterable<QueryFilter> get filters;

  Map<String, String> toQueryParameters({required int page}) {
    return {
      if (search.trim().isNotEmpty) 'search': search.trim(),
      for (final filter in filters) filter.parameter: filter.value,
      'ordering': ordering.apiValue,
      'page': '$page',
    };
  }
}

abstract interface class QueryOrdering {
  String get apiValue;
}

abstract interface class QueryFilterSet {
  Iterable<QueryFilter> get filters;
}

class QueryFilter {
  const QueryFilter({required this.parameter, required this.value});

  final String parameter;
  final String value;
}
