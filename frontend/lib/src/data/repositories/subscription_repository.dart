import '../../core/result.dart';
import '../models/ai_chat.dart';
import '../models/relay_installation_status.dart';
import '../services/pos_api_service.dart';

/// Read-only access to the shop's relay installation and subscription state:
/// the installation ID, the remote-access + AI entitlements, and the current AI
/// usage windows. Powers the subscription status page in Shop Settings. All
/// calls are wrapped in [Result] so the view model can branch without try/catch.
class SubscriptionRepository {
  const SubscriptionRepository(this._service);

  final PosApiService _service;

  /// Loads the installation snapshot. Pass [sync] to refresh from the relay
  /// control server first (fails with [Result] error if the relay is down).
  Future<Result<RelayInstallationStatus>> loadStatus({bool sync = false}) {
    return Result.guard(
      () => _service.fetchRelayInstallationStatus(sync: sync),
    );
  }

  /// Current 5h + weekly AI usage. Only meaningful when AI is entitled; the
  /// backend returns 403 otherwise, surfaced here as a [Result] error.
  Future<Result<AiUsage>> loadAiUsage() {
    return Result.guard(_service.fetchAiUsage);
  }
}
