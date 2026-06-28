import '../models/dashboard.dart';
import '../models/dashboard_ai_digest.dart';
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

  Future<DashboardAiDigest> fetchAiDigest({required int days}) async {
    final response = await _session.get(
      'ai/dashboard-digest/',
      query: {'days': days.toString()},
    );
    _session.ensureSuccess(
      response,
      'Dashboard AI digest request failed with status',
    );
    return DashboardAiDigest.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
