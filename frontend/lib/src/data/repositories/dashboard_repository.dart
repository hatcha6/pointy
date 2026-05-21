import '../../core/result.dart';
import '../models/dashboard.dart';
import '../services/pos_api_service.dart';

class DashboardRepository {
  DashboardRepository(this._service);

  final PosApiService _service;

  Future<Result<DashboardSnapshot>> loadDashboard({required int days}) {
    return Result.guard(() => _service.fetchDashboard(days: days));
  }
}
