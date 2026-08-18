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

  /// Same filters, keyed by an opaque keyset cursor instead of a page number.
  /// Used by the feeds that are still being written to while they are read
  /// (see [nextPageCursor]).
  Map<String, String> toCursorQueryParameters({String? cursor}) {
    return {
      if (search.trim().isNotEmpty) 'search': search.trim(),
      for (final filter in filters) filter.parameter: filter.value,
      'ordering': ordering.apiValue,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    };
  }
}

/// Pulls the opaque `cursor` value out of a paginated response's `next` link.
///
/// The backend paginates the live register feeds by cursor rather than by page
/// number: a page number is an OFFSET into a list that is still growing at its
/// head, so a sale rung up between two pages pushes the list down and the rows
/// written since the first page are never served at all. The cursor anchors the
/// next page to the last row the client actually received.
///
/// Only the query parameter is kept, never the absolute URL the server built —
/// that URL names the backend's own host, which is not necessarily how this
/// client reaches it (LAN address, relay tunnel).
String? nextPageCursor(Object? next) {
  if (next is! String || next.isEmpty) {
    return null;
  }
  final cursor = Uri.tryParse(next)?.queryParameters['cursor'];
  return (cursor == null || cursor.isEmpty) ? null : cursor;
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
