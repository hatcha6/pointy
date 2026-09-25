import '../../core/result.dart';
import '../models/integration_card.dart';
import '../models/integration_provider.dart';
import '../models/integration_recent_search.dart';
import '../models/portal_payment.dart';
import '../models/voucher_availability.dart';
import '../services/pos_api_service.dart';

/// Access to the shop's resale-provider accounts (HD Box and friends) and the
/// Test-connection action. Every call is wrapped in [Result] so the view model
/// can branch without try/catch. Powers Shop Settings → Integrations.
class IntegrationsRepository {
  const IntegrationsRepository(this._service);

  final PosApiService _service;

  Future<Result<List<IntegrationProvider>>> loadProviders() {
    return Result.guard(_service.fetchIntegrationProviders);
  }

  Future<Result<IntegrationProvider>> saveCredentials(
    String providerKey,
    IntegrationCredentialsDraft draft,
  ) {
    return Result.guard(
      () => _service.saveIntegrationCredentials(providerKey, draft),
    );
  }

  Future<Result<IntegrationProvider>> disconnect(String providerKey) {
    return Result.guard(() => _service.disconnectIntegration(providerKey));
  }

  Future<Result<IntegrationProbeResult>> probe(String providerKey) {
    return Result.guard(() => _service.probeIntegration(providerKey));
  }

  Future<Result<IntegrationVerificationChallenge>> startVerification(
    String providerKey,
  ) {
    return Result.guard(
      () => _service.startIntegrationVerification(providerKey),
    );
  }

  Future<Result<IntegrationVerificationStep>> sendVerificationCode(
    String providerKey, {
    required String challengeRef,
    required String answer,
  }) {
    return Result.guard(
      () => _service.sendIntegrationVerificationCode(
        providerKey,
        challengeRef: challengeRef,
        answer: answer,
      ),
    );
  }

  Future<Result<IntegrationVerificationStep>> confirmVerification(
    String providerKey, {
    required String code,
  }) {
    return Result.guard(
      () => _service.confirmIntegrationVerification(providerKey, code: code),
    );
  }

  Future<Result<IntegrationProfileList>> loadProfiles(String providerKey) {
    return Result.guard(() => _service.fetchIntegrationProfiles(providerKey));
  }

  Future<Result<IntegrationProvider?>> chooseProfile(
    String providerKey,
    String profileId,
  ) {
    return Result.guard(
      () => _service.chooseIntegrationProfile(providerKey, profileId),
    );
  }

  /// A card product's cards as the provider has them now. For the till's
  /// picker, which opens without waiting for it.
  Future<Result<VoucherAvailability>> loadVoucherAvailability(int productId) {
    return Result.guard(() => _service.fetchVoucherAvailability(productId));
  }

  Future<Result<IntegrationCardSnapshot>> lookupCard({
    required String providerKey,
    required String cardNo,
    String searchBy = '',
  }) {
    return Result.guard(
      () => _service.fetchIntegrationCard(
        providerKey: providerKey,
        cardNo: cardNo,
        searchBy: searchBy,
      ),
    );
  }

  /// Perform the recharges a sale sold. The guard lives on the server: a
  /// repeat of this call cannot produce a second charge.
  Future<Result<List<IntegrationChargeResult>>> charge({
    int? orderId,
    int? fulfillmentId,
  }) {
    return Result.guard(
      () => _service.chargeIntegrationRecharges(
        orderId: orderId,
        fulfillmentId: fulfillmentId,
      ),
    );
  }

  Future<Result<IntegrationHistoryPage>> loadHistory({
    required String providerKey,
    required String cardNo,
    required IntegrationHistoryKind kind,
    int limit = 10,
    int offset = 0,
  }) {
    return Result.guard(
      () => _service.fetchIntegrationHistory(
        providerKey: providerKey,
        cardNo: cardNo,
        kind: kind,
        limit: limit,
        offset: offset,
      ),
    );
  }

  /// The searches that found something at this provider, newest first, one
  /// cursor page at a time. [search] narrows them as the cashier types.
  Future<Result<IntegrationRecentSearchPage>> loadRecentSearches({
    required String providerKey,
    String search = '',
    String? cursor,
  }) {
    return Result.guard(
      () => _service.fetchIntegrationRecentSearches(
        providerKey: providerKey,
        search: search,
        cursor: cursor,
      ),
    );
  }

  /// One shop-local day of payments made on the provider's own website.
  Future<Result<PortalPaymentsDay>> loadPortalPayments(
    String providerKey, {
    DateTime? date,
    bool refresh = true,
  }) {
    return Result.guard(
      () => _service.fetchPortalPayments(
        providerKey,
        date: date,
        refresh: refresh,
      ),
    );
  }

  /// Issue the invoice for one website payment; a refusal comes back as a
  /// [PortalPaymentRefusal] carrying the server's code.
  Future<Result<PortalPaymentOrder>> recordPortalPayment(
    String providerKey,
    String reference,
    PortalPaymentRecordDraft draft,
  ) {
    return Result.guard(
      () => _service.recordPortalPayment(providerKey, reference, draft),
    );
  }

  Future<Result<PortalPaymentOrder>> linkPortalPayment(
    String providerKey,
    String reference, {
    required int fulfillmentId,
  }) {
    return Result.guard(
      () => _service.linkPortalPayment(
        providerKey,
        reference,
        fulfillmentId: fulfillmentId,
      ),
    );
  }

  Future<Result<IntegrationPriceList>> loadPrices(String providerKey) {
    return Result.guard(() => _service.fetchIntegrationPrices(providerKey));
  }

  Future<Result<IntegrationPriceList>> savePrices(
    String providerKey,
    Map<String, double?> prices,
  ) {
    return Result.guard(
      () => _service.saveIntegrationPrices(providerKey, prices),
    );
  }

  Future<Result<IntegrationFloat>> loadFloat(String providerKey) {
    return Result.guard(() => _service.fetchIntegrationFloat(providerKey));
  }

  Future<Result<IntegrationFloat>> recordTopUp(
    String providerKey, {
    required double amount,
    int? fromAccountId,
    String reference = '',
    String note = '',
  }) {
    return Result.guard(
      () => _service.recordIntegrationTopUp(
        providerKey,
        amount: amount,
        fromAccountId: fromAccountId,
        reference: reference,
        note: note,
      ),
    );
  }

  Future<Result<IntegrationSubscriber>> identifySubscriber(
    String providerKey,
    String subscriberRef, {
    int? customerId,
    String? displayName,
  }) {
    return Result.guard(
      () => _service.identifyIntegrationSubscriber(
        providerKey,
        subscriberRef,
        customerId: customerId,
        displayName: displayName,
      ),
    );
  }
}
