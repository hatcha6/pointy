import '../../core/result.dart';
import '../models/dashboard.dart';
import '../models/dashboard_ai_digest.dart';
import '../services/pos_api_service.dart';

class DashboardRepository {
  DashboardRepository(this._service);

  final PosApiService _service;

  /// Short-TTL memory cache per period. The login refresh and quick
  /// navigation round-trips otherwise refetch a payload the server itself
  /// only recomputes every ~30s (its per-section cache) — within this window
  /// the request never leaves the device. The AI digest is deliberately not
  /// cached here: it has its own per-day server cache and fills in lazily.
  static const Duration _snapshotTtl = Duration(seconds: 45);
  final Map<int, ({DashboardSnapshot snapshot, DateTime fetchedAt})>
  _snapshotsByDays = {};

  Future<Result<DashboardSnapshot>> loadDashboard({required int days}) async {
    final cached = _snapshotsByDays[days];
    if (cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _snapshotTtl) {
      return Ok(cached.snapshot);
    }
    final result = await Result.guard(
      () => _service.fetchDashboard(days: days),
    );
    if (result is Ok<DashboardSnapshot>) {
      _snapshotsByDays[days] = (
        snapshot: result.value,
        fetchedAt: DateTime.now(),
      );
    }
    return result;
  }

  Future<Result<DashboardAiDigest>> loadAiDigest({required int days}) {
    return Result.guard(() => _service.fetchDashboardAiDigest(days: days));
  }
}
