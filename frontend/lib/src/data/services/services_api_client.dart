import '../models/service_country_detail.dart';
import '../models/service_kinds.dart';
import '../models/service_quote.dart';
import '../models/services_directory.dart';
import 'api_session.dart';

/// REST access to «كروت دفتر»' direct services — airtime sent to a phone
/// abroad, bills paid abroad — under `/api/integrations/services/`.
///
/// Reads never reach the relay except [detect], which asks it live which
/// network a number belongs to; the directory, a country and a quote are all
/// answered from the shop backend's mirror.
class ServicesApiClient {
  const ServicesApiClient(this._session);

  final PosApiSession _session;

  /// Every country, with counts and calling codes — no networks, no flags.
  Future<ServicesDirectory> fetchDirectory() async {
    final response = await _session.get('integrations/services/directory/');
    _session.throwApiException(response, 'Loading the services failed');
    final decoded = _session.decodedBody(response);
    return decoded is Map<String, Object?>
        ? ServicesDirectory.fromJson(decoded)
        : ServicesDirectory.empty;
  }

  /// One country's networks and bill providers, with their amounts and prices.
  Future<ServiceCountryDetail> fetchCountry(String code) async {
    final response = await _session.get(
      'integrations/services/countries/${Uri.encodeComponent(code.toUpperCase())}/',
    );
    _session.throwApiException(response, 'Loading the country failed');
    final decoded = _session.decodedBody(response);
    if (decoded is! Map<String, Object?>) {
      return ServiceCountryDetail(country: ServiceCountry(code: code));
    }
    return ServiceCountryDetail.fromJson(decoded);
  }

  /// The network the relay places a number on, asked live.
  ///
  /// A POST with a JSON body, never a GET: a recipient's phone number must not
  /// travel in a URL, where proxies, access logs and browser history keep it.
  Future<OperatorDetection> detect({
    required String country,
    required String phone,
  }) async {
    final response = await _session.post(
      'integrations/services/detect/',
      body: {'country': country.toUpperCase(), 'phone': phone},
      timeout: const Duration(seconds: 25),
    );
    _session.throwApiException(response, 'Detecting the network failed');
    final decoded = _session.decodedBody(response);
    return decoded is Map<String, Object?>
        ? OperatorDetection.fromJson(decoded)
        : const OperatorDetection(detected: false);
  }

  /// The exact price of one thing. A refusal is an answer, not an error.
  Future<ServiceQuoteOutcome> quote(ServiceQuoteRequest request) async {
    final response = await _session.post(
      'integrations/services/quote/',
      body: request.toJson(),
      timeout: const Duration(seconds: 20),
    );
    final decoded = _session.decodedBodyOrNull(response);
    if (decoded is Map<String, Object?>) {
      final succeeded = response.statusCode >= 200 && response.statusCode < 300;
      if (succeeded ||
          decoded['ok'] == false ||
          decoded['error_code'] != null) {
        return ServiceQuoteOutcome.fromJson(decoded, kind: request.kind);
      }
    }
    _session.throwApiException(response, 'Pricing the service failed');
    return const ServiceQuoteOutcome.refused(
      ServiceQuoteRefusal(errorCode: ServiceRefusalCode.unreachable),
    );
  }

  /// The last recipients sold to, newest first, one per number.
  Future<List<RecentRecipient>> fetchRecent(ServiceKind kind) async {
    final response = await _session.get(
      'integrations/services/recent/',
      query: {'kind': serviceKindToJson(kind)},
    );
    _session.throwApiException(response, 'Loading recent recipients failed');
    final decoded = _session.decodedBody(response);
    final rows = decoded is Map<String, Object?>
        ? (decoded['results'] ?? decoded['recent'] ?? decoded['recipients'])
        : decoded;
    return [
      ...jsonRecents(rows).where((recipient) => recipient.phone.isNotEmpty),
    ];
  }
}

/// The recipients in a response, whichever way the server wrapped them.
List<RecentRecipient> jsonRecents(Object? rows) {
  if (rows is! List) {
    return const [];
  }
  return [
    for (final row in rows)
      if (row is Map<String, Object?>) RecentRecipient.fromJson(row),
  ];
}
