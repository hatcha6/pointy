import '../models/unit_of_measure.dart';
import 'api_session.dart';

class UnitOfMeasurePage {
  const UnitOfMeasurePage({required this.units, required this.hasMore});

  final List<UnitOfMeasure> units;
  final bool hasMore;
}

class UnitOfMeasureApiClient {
  const UnitOfMeasureApiClient(this._session);

  final PosApiSession _session;

  Future<UnitOfMeasurePage> fetchUnits({int page = 1, bool? active}) async {
    final response = await _session.get(
      'units-of-measure/',
      query: {
        'page': '$page',
        if (active != null) 'is_active': active ? 'true' : 'false',
      },
      conditionalCache: true, // rides the catalog-version ETag
    );
    _session.ensureSuccess(response, 'Units request failed with status');
    final body = _session.decodedBody(response) as Map<String, Object?>;
    final results = body['results'];
    final units = results is List<Object?>
        ? results
              .whereType<Map<String, Object?>>()
              .map(UnitOfMeasure.fromJson)
              .toList(growable: false)
        : const <UnitOfMeasure>[];
    return UnitOfMeasurePage(units: units, hasMore: body['next'] != null);
  }

  Future<UnitOfMeasure> createUnit(UnitOfMeasureDraft draft) async {
    final response = await _session.post(
      'units-of-measure/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(response, 'Unit create failed with status');
    return UnitOfMeasure.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<UnitOfMeasure> updateUnit({
    required int id,
    required Map<String, Object?> changes,
  }) async {
    final response = await _session.patch(
      'units-of-measure/$id/',
      body: changes,
    );
    _session.ensureSuccess(response, 'Unit update failed with status');
    return UnitOfMeasure.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteUnit(int id) async {
    final response = await _session.delete('units-of-measure/$id/');
    _session.ensureSuccess(response, 'Unit delete failed with status');
  }
}
