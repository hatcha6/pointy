import '../models/dashboard.dart';
import 'api_session.dart';

class DashboardApiClient {
  const DashboardApiClient(this._session);

  final PosApiSession _session;

  Future<DashboardSnapshot> fetchDashboard({required int days}) async {
    final response = await _session.get(
      'dashboard/',
      query: {'days': days.toString()},
    );
    _session.ensureSuccess(response, 'Dashboard request failed with status');
    return DashboardSnapshot.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
