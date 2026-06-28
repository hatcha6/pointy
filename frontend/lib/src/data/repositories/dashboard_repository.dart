import '../../core/result.dart';
import '../models/dashboard.dart';
import '../models/dashboard_ai_digest.dart';
import '../services/pos_api_service.dart';

class DashboardRepository {
  DashboardRepository(this._service);

  final PosApiService _service;

  Future<Result<DashboardSnapshot>> loadDashboard({required int days}) {
    return Result.guard(() => _service.fetchDashboard(days: days));
  }

  Future<Result<DashboardAiDigest>> loadAiDigest({required int days}) {
    return Result.guard(() => _service.fetchDashboardAiDigest(days: days));
  }
}
