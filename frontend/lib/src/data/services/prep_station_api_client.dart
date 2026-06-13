import '../models/prep_station.dart';
import 'api_session.dart';

class PrepStationApiClient {
  const PrepStationApiClient(this._session);

  final PosApiSession _session;

  Future<PrepStationPage> fetchPrepStations({int page = 1}) async {
    final response = await _session.get(
      'prep-stations/',
      query: {'page': '$page'},
    );
    _session.ensureSuccess(
      response,
      'Prep stations request failed with status',
    );
    return PrepStationPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PrepStation> createPrepStation(PrepStationDraft draft) async {
    final response = await _session.post(
      'prep-stations/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Prep station create failed with status',
    );
    return PrepStation.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PrepStation> updatePrepStation(
    int stationId,
    Map<String, Object?> changes,
  ) async {
    final response = await _session.patch(
      'prep-stations/$stationId/',
      body: changes,
    );
    _session.ensureSuccess(
      response,
      'Prep station update failed with status',
    );
    return PrepStation.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deletePrepStation(int stationId) async {
    final response = await _session.delete('prep-stations/$stationId/');
    _session.ensureSuccess(
      response,
      'Prep station delete failed with status',
    );
  }
}
