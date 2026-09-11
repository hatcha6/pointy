import 'dart:typed_data';

import '../models/scale.dart';
import 'api_session.dart';

/// The shop's weighing scales: what they are, and the push.
class ScalesApiClient {
  const ScalesApiClient(this._session);

  final PosApiSession _session;

  Future<List<Scale>> fetchScales() async {
    final response = await _session.get('scales/', query: {'page_size': '100'});
    _session.ensureSuccess(response, 'Scales request failed with status');
    final body = _session.decodedBody(response) as Map<String, Object?>;
    final results = body['results'];
    if (results is! List<Object?>) {
      return const <Scale>[];
    }
    return results
        .whereType<Map<String, Object?>>()
        .map(Scale.fromJson)
        .toList(growable: false);
  }

  Future<List<ScaleDriverInfo>> fetchDrivers() async {
    final response = await _session.get('scales/drivers/');
    _session.ensureSuccess(
      response,
      'Scale drivers request failed with status',
    );
    final body = _session.decodedBody(response);
    if (body is! List<Object?>) {
      return const <ScaleDriverInfo>[];
    }
    return body
        .whereType<Map<String, Object?>>()
        .map(ScaleDriverInfo.fromJson)
        .toList(growable: false);
  }

  Future<Scale> createScale(Map<String, Object?> draft) async {
    final response = await _session.post('scales/', body: draft);
    _session.ensureSuccess(response, 'Scale create failed with status');
    return Scale.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Scale> updateScale({
    required int id,
    required Map<String, Object?> changes,
  }) async {
    final response = await _session.patch('scales/$id/', body: changes);
    _session.ensureSuccess(response, 'Scale update failed with status');
    return Scale.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteScale(int id) async {
    final response = await _session.delete('scales/$id/');
    _session.ensureSuccess(response, 'Scale delete failed with status');
  }

  Future<ScaleReachability> checkScale(int id) async {
    final response = await _session.post('scales/$id/check/', body: const {});
    _session.ensureSuccess(response, 'Scale check failed with status');
    return ScaleReachability.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ScalePushJob> pushScale(int id) async {
    final response = await _session.post('scales/$id/push/', body: const {});
    _session.ensureSuccess(response, 'Scale push failed with status');
    return ScalePushJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<ScalePushJob>> fetchPushes(int id) async {
    final response = await _session.get('scales/$id/pushes/');
    _session.ensureSuccess(
      response,
      'Scale history request failed with status',
    );
    final body = _session.decodedBody(response);
    if (body is! List<Object?>) {
      return const <ScalePushJob>[];
    }
    return body
        .whereType<Map<String, Object?>>()
        .map(ScalePushJob.fromJson)
        .toList(growable: false);
  }

  /// The PLU file itself, for a scale that is loaded by hand.
  Future<(String, Uint8List)> exportPluFile(int id) async {
    final response = await _session.get('scales/$id/export/');
    _session.ensureSuccess(response, 'Scale export failed with status');
    final disposition = response.headers['content-disposition'] ?? '';
    final match = RegExp('filename="([^"]+)"').firstMatch(disposition);
    return (match?.group(1) ?? 'plu.csv', response.bodyBytes);
  }

  Future<List<ScalePlu>> fetchPlus() async {
    final response = await _session.get(
      'scale-plus/',
      query: {'page_size': '200'},
    );
    _session.ensureSuccess(response, 'PLU request failed with status');
    final body = _session.decodedBody(response) as Map<String, Object?>;
    final results = body['results'];
    if (results is! List<Object?>) {
      return const <ScalePlu>[];
    }
    return results
        .whereType<Map<String, Object?>>()
        .map(ScalePlu.fromJson)
        .toList(growable: false);
  }

  Future<ScalePlu> assignPlu({
    required int variantId,
    String labelName = '',
    int tareGrams = 0,
    int? shelfLifeDays,
  }) async {
    final response = await _session.post(
      'scale-plus/',
      body: {
        'variant': variantId,
        'label_name': labelName,
        'tare_grams': tareGrams,
        'shelf_life_days': ?shelfLifeDays,
      },
    );
    _session.ensureSuccess(response, 'PLU assign failed with status');
    return ScalePlu.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ScalePlu> updatePlu({
    required int id,
    required Map<String, Object?> changes,
  }) async {
    final response = await _session.patch('scale-plus/$id/', body: changes);
    _session.ensureSuccess(response, 'PLU update failed with status');
    return ScalePlu.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
