import '../models/currency.dart';
import 'api_session.dart';

/// The one FX read a till needs.
///
/// Main's client also fetches rate history, records manual rates and drives
/// repricing. None of that happens at a till — a sale never re-reads a rate,
/// it prices off the stored base price — so this build asks only for the
/// currency list, which is what turns a foreign price from a bare ISO code
/// into a symbol a cashier can read.
class FxApiClient {
  const FxApiClient(this._session);

  final PosApiSession _session;

  Future<List<Currency>> fetchCurrencies() async {
    final response = await _session.get(
      'currencies/',
      query: {'page_size': '100'},
    );
    _session.ensureSuccess(response, 'Currencies request failed with status');
    final body = _session.decodedBody(response);
    final rows = body is Map<String, Object?>
        ? (body['results'] as List<Object?>? ?? const <Object?>[])
        : (body as List<Object?>? ?? const <Object?>[]);
    return rows
        .whereType<Map<String, Object?>>()
        .map(Currency.fromJson)
        .toList();
  }
}
