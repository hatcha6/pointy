import '../../shared/barcode/scale_barcode.dart';
import 'api_session.dart';

/// How this shop's scales lay out the labels they print.
///
/// Rides the catalog-version ETag like the other catalog reads, so a till that
/// re-checks the rules on every session start pays one 304 for the privilege.
class ScaleBarcodeRuleApiClient {
  const ScaleBarcodeRuleApiClient(this._session);

  final PosApiSession _session;

  Future<List<ScaleBarcodeRule>> fetchRules({bool activeOnly = true}) async {
    final response = await _session.get(
      'scale-barcode-rules/',
      query: {'page_size': '100', if (activeOnly) 'is_active': 'true'},
      conditionalCache: true,
    );
    _session.ensureSuccess(response, 'Scale rules request failed with status');
    final body = _session.decodedBody(response) as Map<String, Object?>;
    final results = body['results'];
    if (results is! List<Object?>) {
      return const <ScaleBarcodeRule>[];
    }
    return results
        .whereType<Map<String, Object?>>()
        .map(ScaleBarcodeRule.fromJson)
        .toList(growable: false);
  }

  Future<ScaleBarcodeRule> createRule(Map<String, Object?> draft) async {
    final response = await _session.post('scale-barcode-rules/', body: draft);
    _session.ensureSuccess(response, 'Scale rule create failed with status');
    return ScaleBarcodeRule.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ScaleBarcodeRule> updateRule({
    required int id,
    required Map<String, Object?> changes,
  }) async {
    final response = await _session.patch(
      'scale-barcode-rules/$id/',
      body: changes,
    );
    _session.ensureSuccess(response, 'Scale rule update failed with status');
    return ScaleBarcodeRule.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteRule(int id) async {
    final response = await _session.delete('scale-barcode-rules/$id/');
    _session.ensureSuccess(response, 'Scale rule delete failed with status');
  }
}
