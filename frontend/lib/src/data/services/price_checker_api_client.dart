import '../models/price_check_event.dart';
import '../models/price_checker_device.dart';
import 'api_session.dart';

/// Talks to the price-checker device + scan-event endpoints. These are
/// manager-gated on the backend; the client just surfaces the data.
class PriceCheckerApiClient {
  const PriceCheckerApiClient(this._session);

  final PosApiSession _session;

  Future<List<PriceCheckerDevice>> fetchDevices({int page = 1}) async {
    final response = await _session.get(
      'price-checker-devices/',
      query: {'page': '$page'},
    );
    _session.ensureSuccess(
      response,
      'Price-checker devices request failed with status',
    );
    return priceCheckerDevicesFromResponse(_session.decodedBody(response));
  }

  /// Triggers an on-demand LAN scan; the backend registers what it finds and
  /// returns a summary.
  Future<PriceCheckerScanSummary> runScan() async {
    final response = await _session.post('price-checker-devices/scan/');
    _session.ensureSuccess(
      response,
      'Price-checker scan failed with status',
    );
    final decoded = _session.decodedBody(response);
    return PriceCheckerScanSummary.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  Future<List<PriceCheckEvent>> fetchEvents({int? deviceId, int page = 1}) async {
    final response = await _session.get(
      'price-check-events/',
      query: {
        'page': '$page',
        if (deviceId != null) 'device': '$deviceId',
      },
    );
    _session.ensureSuccess(
      response,
      'Price-check events request failed with status',
    );
    return priceCheckEventsFromResponse(_session.decodedBody(response));
  }
}
