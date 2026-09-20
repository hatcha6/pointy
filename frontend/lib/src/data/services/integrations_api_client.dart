import '../models/integration_card.dart';
import '../models/integration_provider.dart';
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
  Future<IntegrationCardSnapshot> fetchCard({
    required String providerKey,
    required String cardNo,
  }) async {
    final response = await _session.get(
      'integrations/$providerKey/card/',
      query: {'card_no': cardNo},
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
