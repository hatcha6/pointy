import '../models/business_alert.dart';
import 'api_session.dart';

class BusinessNotificationApiClient {
  const BusinessNotificationApiClient(this._session);

  final PosApiSession _session;

  Future<BusinessAlertDigest> fetchNotifications({
    bool includeHidden = true,
  }) async {
    final response = await _session.get(
      'business-notifications/',
      query: {'include_hidden': includeHidden.toString()},
    );
    _session.ensureSuccess(
      response,
      'Business notification request failed with status',
    );
    final decoded = _session.decodedBody(response);
    final decodedMap = _mapFromJson(decoded);
    final items = decodedMap.isNotEmpty
        ? _listFromJson(decodedMap['results'])
        : _listFromJson(decoded);
    return BusinessAlertDigest(
      alerts: items
          .map(_mapFromJson)
          .where((item) => item.isNotEmpty)
          .map(BusinessAlert.fromJson)
          .toList(growable: false),
      generatedAt: DateTime.now(),
    );
  }

  Future<BusinessAlert> dismissNotification(String id) {
    return _postNotificationAction(id, 'dismiss');
  }

  Future<BusinessAlert> snoozeNotification(String id, {required int hours}) {
    return _postNotificationAction(id, 'snooze', body: {'hours': hours});
  }

  Future<BusinessAlert> restoreNotification(String id) {
    return _postNotificationAction(id, 'restore');
  }

  Future<void> dismissAllNotifications() async {
    final response = await _session.post('business-notifications/dismiss-all/');
    _session.ensureSuccess(
      response,
      'Dismiss business notifications request failed with status',
    );
  }

  Future<void> restoreHiddenNotifications() async {
    final response = await _session.post(
      'business-notifications/restore-hidden/',
    );
    _session.ensureSuccess(
      response,
      'Restore business notifications request failed with status',
    );
  }

  Future<BusinessAlert> _postNotificationAction(
    String id,
    String action, {
    Object? body,
  }) async {
    final response = await _session.post(
      'business-notifications/$id/$action/',
      body: body,
    );
    _session.ensureSuccess(
      response,
      'Business notification action failed with status',
    );
    return BusinessAlert.fromJson(_mapFromJson(_session.decodedBody(response)));
  }
}

List<Object?> _listFromJson(Object? value) {
  return value is List ? value.cast<Object?>() : const [];
}

Map<String, Object?> _mapFromJson(Object? value) {
  if (value is! Map) {
    return const {};
  }
  return value.map((key, value) => MapEntry(key.toString(), value));
}
