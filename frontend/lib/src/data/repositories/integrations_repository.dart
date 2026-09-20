import '../../core/result.dart';
import '../models/integration_card.dart';
import '../models/integration_provider.dart';
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

  Future<Result<IntegrationCardSnapshot>> lookupCard({
    required String providerKey,
    required String cardNo,
  }) {
    return Result.guard(
      () => _service.fetchIntegrationCard(
        providerKey: providerKey,
        cardNo: cardNo,
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
