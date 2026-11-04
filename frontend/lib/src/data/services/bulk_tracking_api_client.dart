import '../models/bulk_tracking_change.dart';
import 'api_session.dart';

/// `bulk-tracking-changes/` — moving products onto expiry tracking in bulk.
class BulkTrackingApiClient {
  const BulkTrackingApiClient(this._session);

  final PosApiSession _session;

  Future<BulkTrackingPreview> preview({
    required BulkTrackingAction action,
    required Map<String, Object?> filter,
  }) async {
    final response = await _session.post(
      'bulk-tracking-changes/preview/',
      body: action.toJson(filter: filter),
    );
    _session.throwApiException(response, 'Bulk tracking preview failed');
    return BulkTrackingPreview.fromJson(_map(_session.decodedBody(response)));
  }

  /// One batch (the server takes 1-200 ids). Safe to send again.
  Future<BulkTrackingApplyResult> apply({
    required BulkTrackingAction action,
    required Map<String, Object?> filter,
    required List<int> productIds,
  }) async {
    final response = await _session.post(
      'bulk-tracking-changes/apply/',
      body: action.toJson(filter: filter, productIds: productIds),
    );
    _session.throwApiException(response, 'Bulk tracking apply failed');
    return BulkTrackingApplyResult.fromJson(
      _map(_session.decodedBody(response)),
    );
  }

  static Map<String, dynamic> _map(Object? body) =>
      body is Map ? body.cast<String, dynamic>() : const {};
}
