import '../../core/result.dart';
import '../models/prep_station.dart';
import '../services/pos_api_service.dart';

class PrepStationRepository {
  PrepStationRepository(this._service);

  final PosApiService _service;

  Future<Result<List<PrepStation>>> loadStations() async {
    return Result.guard(() async {
      final stations = <PrepStation>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchPrepStations(page: page);
        stations.addAll(result.stations);
        hasMore = result.hasMore;
        page += 1;
      }
      return stations;
    });
  }

  Future<Result<PrepStation>> createStation(PrepStationDraft draft) async {
    return Result.guard(() => _service.createPrepStation(draft));
  }

  Future<Result<PrepStation>> updateStation(
    int stationId,
    Map<String, Object?> changes,
  ) async {
    return Result.guard(() => _service.updatePrepStation(stationId, changes));
  }

  Future<Result<void>> deleteStation(int stationId) async {
    return Result.guard(() => _service.deletePrepStation(stationId));
  }
}
