import '../models/search_miss.dart';
import 'api_session.dart';

/// The catalogue's "searched but not found" worklist (`/search-misses/`).
///
/// Every call needs `catalog.change_product`: teaching the catalogue a word is
/// editing products. Failures throw [PosApiException] with the body kept, so a
/// refused product (`{"product": [...]}`) can be told apart from a dropped
/// request.
class SearchMissApiClient {
  const SearchMissApiClient(this._session);

  final PosApiSession _session;

  /// One page, most typed first.
  Future<SearchMissPage> fetchPage({
    int page = 1,
    SearchMissFilter filter = SearchMissFilter.open,
  }) async {
    final response = await _session.get(
      'search-misses/',
      query: {'page': '$page', 'status': filter.apiValue},
    );
    _session.throwApiException(response, 'Search misses request failed');
    return SearchMissPage.fromAny(_session.decodedBody(response));
  }

  /// Teaches the catalogue the row's word as a name of [productId].
  Future<SearchMiss> resolve(int id, {required int productId}) {
    return _act(id, 'resolve', body: {'product': productId});
  }

  Future<SearchMiss> dismiss(int id) => _act(id, 'dismiss');

  Future<SearchMiss> reopen(int id) => _act(id, 'reopen');

  Future<SearchMiss> _act(
    int id,
    String action, {
    Map<String, Object?> body = const {},
  }) async {
    final response = await _session.post(
      'search-misses/$id/$action/',
      body: body,
    );
    _session.throwApiException(response, 'Search miss $action failed');
    return SearchMiss.fromJson(
      (_session.decodedBody(response) as Map).cast<String, Object?>(),
    );
  }
}
