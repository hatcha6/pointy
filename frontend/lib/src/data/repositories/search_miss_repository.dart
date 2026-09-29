import '../../core/result.dart';
import '../models/search_miss.dart';
import '../services/pos_api_service.dart';

/// The words the catalogue's search found nothing for, and what the owner
/// says each one meant.
class SearchMissRepository {
  const SearchMissRepository(this._service);

  final PosApiService _service;

  Future<Result<SearchMissPage>> loadMisses({
    int page = 1,
    SearchMissFilter filter = SearchMissFilter.open,
  }) {
    return Result.guard(
      () => _service.searchMisses.fetchPage(page: page, filter: filter),
    );
  }

  /// From now on, a search for the row's word finds [productId].
  Future<Result<SearchMiss>> resolve(int id, {required int productId}) {
    return Result.guard(
      () => _service.searchMisses.resolve(id, productId: productId),
    );
  }

  Future<Result<SearchMiss>> dismiss(int id) {
    return Result.guard(() => _service.searchMisses.dismiss(id));
  }

  Future<Result<SearchMiss>> reopen(int id) {
    return Result.guard(() => _service.searchMisses.reopen(id));
  }
}
