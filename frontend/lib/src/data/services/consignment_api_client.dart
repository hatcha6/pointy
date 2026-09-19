import '../models/consignment.dart';
import '../models/stock_unit.dart';
import 'api_session.dart';

/// الأمانات over the wire.
///
/// Every money figure here is computed server-side and never cached: a payable
/// the client remembered is a payable that can disagree with the ledger, and
/// the whole design of this module is that it cannot.
class ConsignmentApiClient {
  const ConsignmentApiClient(this._session);

  final PosApiSession _session;

  Future<ConsignmentPayablePage> fetchPayables({
    int? consignorId,
    int page = 1,
    String search = '',
  }) async {
    final response = await _session.get(
      'stock-units/consignment-payables/',
      query: {
        if (consignorId != null) 'consignor': '$consignorId',
        if (page > 1) 'page': '$page',
        if (search.trim().isNotEmpty) 'search': search.trim(),
      },
    );
    _session.ensureSuccess(response, 'Consignment payables failed with status');
    return ConsignmentPayablePage.fromJson(_session.decodedBody(response));
  }

  Future<ConsignmentPosition> fetchPosition({
    DateTime? start,
    DateTime? end,
  }) async {
    final response = await _session.get(
      'inventory/consignment-position/',
      query: {
        if (start != null) 'start': _day(start),
        if (end != null) 'end': _day(end),
      },
    );
    _session.ensureSuccess(response, 'Consignment position failed with status');
    return ConsignmentPosition.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Pay one consignor for however many of their sold articles are being
  /// settled at once — which is what a counter actually does: the owner of
  /// eight handbags collects for three of them and signs once.
  Future<ConsignorPayout> disburse({
    required int unitId,
    List<int> alsoUnitIds = const [],
    String method = 'cash',
    String reference = '',
    String notes = '',
  }) async {
    final response = await _session.post(
      'stock-units/$unitId/disburse-payout/',
      body: {
        'units': alsoUnitIds,
        'method': method,
        if (reference.isNotEmpty) 'reference': reference,
        if (notes.isNotEmpty) 'notes': notes,
      },
    );
    _session.ensureSuccess(response, 'Consignment payout failed with status');
    return ConsignorPayout.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<bool> resendSaleSms(int unitId) async {
    final response = await _session.post(
      'stock-units/$unitId/resend-consignor-sms/',
      body: const {},
    );
    _session.ensureSuccess(response, 'Consignment SMS failed with status');
    final body = _session.decodedBody(response);
    return body is Map<String, Object?> && body['queued'] == true;
  }

  Future<StockUnit> returnToConsignor(int unitId, {String note = ''}) async {
    final response = await _session.post(
      'stock-units/$unitId/return-to-consignor/',
      body: {if (note.isNotEmpty) 'note': note},
    );
    _session.ensureSuccess(response, 'Consignment return failed with status');
    return StockUnit.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<ConsignmentAgreement>> fetchAgreements({
    int? consignorId,
    bool openOnly = false,
  }) async {
    final response = await _session.get(
      'consignment-agreements/',
      query: {
        if (consignorId != null) 'consignor': '$consignorId',
        if (openOnly) 'open_only': 'true',
      },
    );
    _session.ensureSuccess(
      response,
      'Consignment agreements failed with status',
    );
    final body = _session.decodedBody(response);
    final rows = body is Map<String, Object?> ? body['results'] : body;
    if (rows is! List<Object?>) {
      return const [];
    }
    return rows
        .whereType<Map<String, Object?>>()
        .map(ConsignmentAgreement.fromJson)
        .toList(growable: false);
  }

  Future<ConsignmentAgreement> createAgreement(
    Map<String, Object?> body,
  ) async {
    final response = await _session.post('consignment-agreements/', body: body);
    _session.ensureSuccess(
      response,
      'Consignment agreement failed with status',
    );
    return ConsignmentAgreement.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Sign it, and take the goods in. One call, because a signed page with no
  /// goods behind it is a promise about nothing.
  Future<ConsignmentAgreement> submitAgreement(
    int agreementId, {
    required List<ConsignmentIntakeItem> items,
  }) async {
    final response = await _session.post(
      'consignment-agreements/$agreementId/submit/',
      body: {
        'items': [for (final item in items) item.toJson()],
      },
    );
    _session.ensureSuccess(response, 'Consignment intake failed with status');
    return ConsignmentAgreement.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  static String _day(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }
}
