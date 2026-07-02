import '../models/price_check_event.dart';
import '../models/price_checker_device.dart';
import '../models/price_lookup_result.dart';
import 'api_session.dart';

/// Talks to the price-checker device + scan-event endpoints. These are
/// manager-gated on the backend; the client just surfaces the data.
class PriceCheckerApiClient {
  const PriceCheckerApiClient(this._session);

  final PosApiSession _session;

  /// Scans a barcode against the LAN-allowed lookup endpoint. Works without a
  /// logged-in user (a kiosk on the private network), and attributes the scan
  /// to [deviceIdentifier] when this device has self-registered.
  Future<PriceLookupResult> lookup({
    required String barcode,
    String deviceIdentifier = '',
  }) async {
    final response = await _session.get(
      'price-checker/lookup/',
      query: {
        'barcode': barcode,
        if (deviceIdentifier.isNotEmpty) 'device': deviceIdentifier,
      },
    );
    _session.ensureSuccess(response, 'Price lookup failed with status');
    final decoded = _session.decodedBody(response);
    return PriceLookupResult.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  /// Best-effort self-registration so this kiosk shows up in the fleet list with
  /// live scan history. LAN-allowed; idempotent on [identifier].
  Future<void> registerKiosk({
    required String identifier,
    String name = '',
    String location = '',
  }) async {
    final response = await _session.post(
      'price-checker/register/',
      includeCsrf: false,
      body: {
        'identifier': identifier,
        if (name.isNotEmpty) 'name': name,
        if (location.isNotEmpty) 'location': location,
      },
    );
    _session.ensureSuccess(
      response,
      'Price-checker register failed with status',
    );
  }

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
    _session.ensureSuccess(response, 'Price-checker scan failed with status');
    final decoded = _session.decodedBody(response);
    return PriceCheckerScanSummary.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  Future<List<PriceCheckEvent>> fetchEvents({
    int? deviceId,
    int page = 1,
  }) async {
    final response = await _session.get(
      'price-check-events/',
      query: {'page': '$page', if (deviceId != null) 'device': '$deviceId'},
    );
    _session.ensureSuccess(
      response,
      'Price-check events request failed with status',
    );
    return priceCheckEventsFromResponse(_session.decodedBody(response));
  }
}
