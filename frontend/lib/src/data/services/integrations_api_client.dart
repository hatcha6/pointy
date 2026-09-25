import 'package:http/http.dart' as http;

import '../models/integration_card.dart';
import '../models/integration_provider.dart';
import '../models/integration_recent_search.dart';
import '../models/portal_payment.dart';
import '../models/voucher_availability.dart';
import 'api_session.dart';

/// REST access to the resale-provider endpoints (apps.integrations):
/// `GET /api/integrations/`, `PUT|DELETE /api/integrations/<key>/`, and the
/// per-provider `POST .../probe/` + `GET .../lookup/` actions.
///
/// Addressed by provider key rather than row id: the catalog is fixed, and a
/// shop that has never configured HD Box still needs to see it listed.
class IntegrationsApiClient {
  const IntegrationsApiClient(this._session);

  final PosApiSession _session;

  Future<List<IntegrationProvider>> fetchProviders() async {
    final response = await _session.get('integrations/');
    _session.throwApiException(
      response,
      'Integrations request failed with status',
    );
    final decoded = _session.decodedBody(response);
    final items = decoded is Map<String, Object?>
        ? (decoded['providers'] as List<Object?>? ?? const [])
        : const <Object?>[];
    return items
        .whereType<Map<String, Object?>>()
        .map(IntegrationProvider.fromJson)
        .toList();
  }

  Future<IntegrationProvider> saveCredentials(
    String providerKey,
    IntegrationCredentialsDraft draft,
  ) async {
    final response = await _session.put(
      'integrations/$providerKey/',
      body: draft.toJson(),
    );
    _session.throwApiException(
      response,
      'Saving integration credentials failed with status',
    );
    return IntegrationProvider.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<IntegrationProvider> disconnect(String providerKey) async {
    final response = await _session.delete('integrations/$providerKey/');
    _session.throwApiException(
      response,
      'Disconnecting the integration failed with status',
    );
    return IntegrationProvider.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<IntegrationProbeResult> probe(String providerKey) async {
    final response = await _session.post('integrations/$providerKey/probe/');
    _session.throwApiException(
      response,
      'Testing the integration failed with status',
    );
    return IntegrationProbeResult.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Everything the till needs about one subscriber, in one round trip: the
  /// card, today's prices, and the variant a cart line must point at.
  ///
  /// [searchBy] is what the cashier said the number IS, from the picker
  /// beside the search box. A phone number and a contract number are both
  /// digits, so without it the portal has to be asked every way in turn —
  /// measured at three round trips and ~4.4s against LNET. It orders the
  /// search; a wrong pick is slower, never a customer who cannot be found.
  Future<IntegrationCardSnapshot> fetchCard({
    required String providerKey,
    required String cardNo,
    String searchBy = '',
  }) async {
    final response = await _session.get(
      'integrations/$providerKey/card/',
      query: {
        'card_no': cardNo,
        if (searchBy.isNotEmpty) 'search_by': searchBy,
      },
    );
    _session.throwApiException(response, 'Card lookup failed with status');
    final decoded = _session.decodedBody(response) as Map<String, Object?>;
    if (decoded['ok'] != true) {
      throw IntegrationProviderRefusal(
        decoded['error_code']?.toString() ?? '',
        decoded['error_detail']?.toString() ?? '',
      );
    }
    return IntegrationCardSnapshot.fromJson(decoded);
  }

  /// The searches that found something at this provider, newest first.
  ///
  /// [search] narrows them by the number typed, the line found, or the name
  /// the shop gave the card. Paged by [cursor] — the opaque value from the
  /// previous page's [IntegrationRecentSearchPage.nextCursor].
  Future<IntegrationRecentSearchPage> fetchRecentSearches({
    required String providerKey,
    String search = '',
    String? cursor,
  }) async {
    final response = await _session.get(
      'integrations/$providerKey/searches/',
      query: {
        if (search.isNotEmpty) 'search': search,
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      },
    );
    _session.throwApiException(
      response,
      'Recent searches request failed with status',
    );
    return IntegrationRecentSearchPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// One page of a subscriber's history.
  Future<IntegrationHistoryPage> fetchHistory({
    required String providerKey,
    required String cardNo,
    required IntegrationHistoryKind kind,
    int limit = 10,
    int offset = 0,
  }) async {
    final response = await _session.get(
      'integrations/$providerKey/history/',
      query: {
        'card_no': cardNo,
        'kind': kind == IntegrationHistoryKind.statuses
            ? 'statuses'
            : 'purchases',
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    _session.throwApiException(response, 'History request failed with status');
    return IntegrationHistoryPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<IntegrationPriceList> fetchPrices(String providerKey) async {
    final response = await _session.get('integrations/$providerKey/prices/');
    _session.throwApiException(
      response,
      'Price list request failed with status',
    );
    return IntegrationPriceList.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Send only what changed. A null price clears the override and hands the
  /// option back to the account's fallback markup.
  Future<IntegrationPriceList> savePrices(
    String providerKey,
    Map<String, double?> prices,
  ) async {
    final response = await _session.put(
      'integrations/$providerKey/prices/',
      body: {
        'prices': [
          for (final entry in prices.entries)
            {'option_code': entry.key, 'price': entry.value},
        ],
      },
    );
    _session.throwApiException(response, 'Saving prices failed with status');
    return IntegrationPriceList.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<IntegrationFloat> fetchFloat(String providerKey) async {
    final response = await _session.get('integrations/$providerKey/float/');
    _session.throwApiException(response, 'Float request failed with status');
    return IntegrationFloat.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<IntegrationFloat> recordTopUp(
    String providerKey, {
    required double amount,
    int? fromAccountId,
    String reference = '',
    String note = '',
  }) async {
    final response = await _session.post(
      'integrations/$providerKey/float/',
      body: {
        'amount': amount.toStringAsFixed(2),
        'from_account': ?fromAccountId,
        if (reference.isNotEmpty) 'reference': reference,
        if (note.isNotEmpty) 'note': note,
      },
    );
    _session.throwApiException(
      response,
      'Recording the top-up failed with status',
    );
    return IntegrationFloat.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Perform the recharges a sale has already sold. Spends the agency float.
  ///
  /// Safe to call more than once for the same order: the server allows each
  /// line one attempt ever, so a repeat finds nothing claimable and comes back
  /// with an empty list rather than charging again.
  Future<List<IntegrationChargeResult>> charge({
    int? orderId,
    int? fulfillmentId,
  }) async {
    final response = await _session.post(
      'integrations/fulfillments/charge/',
      body: {'order': ?orderId, 'fulfillment': ?fulfillmentId},
    );
    _session.throwApiException(
      response,
      'Performing the recharge failed with status',
    );
    final decoded = _session.decodedBody(response) as Map<String, Object?>;
    return (decoded['results'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(IntegrationChargeResult.fromJson)
        .toList(growable: false);
  }

  // --- confirming this device with the provider ----------------------------
  Future<IntegrationVerificationChallenge> startVerification(
    String providerKey,
  ) async {
    final response = await _session.post(
      'integrations/$providerKey/verification/',
    );
    _session.throwApiException(response, 'Starting verification failed');
    return IntegrationVerificationChallenge.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<IntegrationVerificationStep> sendVerificationCode(
    String providerKey, {
    required String challengeRef,
    required String answer,
  }) async {
    final response = await _session.post(
      'integrations/$providerKey/verification/send/',
      body: {'challenge_ref': challengeRef, 'answer': answer},
    );
    _session.throwApiException(response, 'Requesting a code failed');
    return IntegrationVerificationStep.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<IntegrationVerificationStep> confirmVerification(
    String providerKey, {
    required String code,
  }) async {
    final response = await _session.post(
      'integrations/$providerKey/verification/confirm/',
      body: {'code': code},
    );
    _session.throwApiException(response, 'Confirming the code failed');
    return IntegrationVerificationStep.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  // --- which profile (shop) the login buys as --------------------------------
  Future<IntegrationProfileList> fetchProfiles(String providerKey) async {
    final response = await _session.get('integrations/$providerKey/profiles/');
    _session.throwApiException(response, 'Loading profiles failed');
    return IntegrationProfileList.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<IntegrationProvider?> chooseProfile(
    String providerKey,
    String profileId,
  ) async {
    final response = await _session.put(
      'integrations/$providerKey/profiles/',
      body: {'profile_id': profileId},
    );
    _session.throwApiException(response, 'Choosing a profile failed');
    final decoded = _session.decodedBody(response);
    final provider = decoded is Map<String, Object?>
        ? decoded['provider']
        : null;
    return provider is Map<String, Object?>
        ? IntegrationProvider.fromJson(provider)
        : null;
  }

  // --- a card product's live availability -------------------------------------
  Future<VoucherAvailability> fetchVoucherAvailability(int productId) async {
    final response = await _session.get('integrations/vouchers/$productId/');
    _session.throwApiException(response, 'Checking card availability failed');
    return VoucherAvailability.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  // --- payments made on the provider's own website ---------------------------
  /// One shop-local day of the provider's payments report, and where each
  /// payment stands in Pointy. [refresh] false answers from the server's copy
  /// without reading the provider first — for a reload right after a write.
  Future<PortalPaymentsDay> fetchPortalPayments(
    String providerKey, {
    DateTime? date,
    bool refresh = true,
  }) async {
    final response = await _session.get(
      'integrations/$providerKey/portal-payments/',
      query: {
        if (date != null) 'date': _isoDate(date),
        if (!refresh) 'refresh': '0',
      },
    );
    _throwPortalRefusal(response, 'Loading website payments failed');
    return PortalPaymentsDay.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Issue the invoice for one website payment. Throws [PortalPaymentRefusal]
  /// with the server's stable code when it will not.
  Future<PortalPaymentOrder> recordPortalPayment(
    String providerKey,
    String reference,
    PortalPaymentRecordDraft draft,
  ) async {
    final response = await _session.post(
      'integrations/$providerKey/portal-payments/'
      '${Uri.encodeComponent(reference)}/record/',
      body: draft.toJson(),
    );
    _throwPortalRefusal(response, 'Recording the website payment failed');
    final decoded = _session.decodedBody(response) as Map<String, Object?>;
    return PortalPaymentOrder.fromJson(
      decoded['order'] as Map<String, Object?>? ?? const {},
    );
  }

  /// This website payment IS the top-up the sale behind [fulfillmentId] was
  /// waiting for. Settles that sale; issues nothing new.
  Future<PortalPaymentOrder> linkPortalPayment(
    String providerKey,
    String reference, {
    required int fulfillmentId,
  }) async {
    final response = await _session.post(
      'integrations/$providerKey/portal-payments/'
      '${Uri.encodeComponent(reference)}/link/',
      body: {'fulfillment': fulfillmentId},
    );
    _throwPortalRefusal(response, 'Linking the website payment failed');
    final decoded = _session.decodedBody(response) as Map<String, Object?>;
    return PortalPaymentOrder.fromJson(
      decoded['order'] as Map<String, Object?>? ?? const {},
    );
  }

  /// A refusal the server explained with a code, else the ordinary failure.
  void _throwPortalRefusal(http.Response response, String message) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final refusal = PortalPaymentRefusal.fromBody(
      _session.decodedBodyOrNull(response),
    );
    if (refusal != null) throw refusal;
    _session.throwApiException(response, message);
  }

  static String _isoDate(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }

  /// Name the person behind a card — the half the provider will not tell us.
  Future<IntegrationSubscriber> identifySubscriber(
    String providerKey,
    String subscriberRef, {
    int? customerId,
    String? displayName,
    bool detachCustomer = false,
  }) async {
    // Built up rather than written as a literal: "link this customer",
    // "unlink whoever is linked" and "leave the link alone" are three
    // different instructions, and a null in a collection-if cannot say
    // which of the last two it means.
    final body = <String, Object?>{};
    if (detachCustomer) {
      body['customer'] = null;
    } else if (customerId != null) {
      body['customer'] = customerId;
    }
    if (displayName != null) {
      body['display_name'] = displayName;
    }
    final response = await _session.put(
      'integrations/$providerKey/subscribers/$subscriberRef/',
      body: body,
    );
    _session.throwApiException(
      response,
      'Naming the subscriber failed with status',
    );
    return IntegrationSubscriber.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}

/// The provider answered, and the answer was no.
///
/// Distinct from [PosApiException] on purpose: our own call succeeded, so the
/// till should render the provider's reason ("no such card") rather than a
/// generic "something went wrong".
class IntegrationProviderRefusal implements Exception {
  const IntegrationProviderRefusal(this.errorCode, [this.errorDetail = '']);

  final String errorCode;
  final String errorDetail;

  @override
  String toString() => 'IntegrationProviderRefusal($errorCode)';
}
