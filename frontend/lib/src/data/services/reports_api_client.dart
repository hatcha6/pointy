import '../models/report_run.dart';
import 'api_session.dart';

class ReportsApiClient {
  const ReportsApiClient(this._session);

  final PosApiSession _session;

  Future<ReportRun> createReportRun(ReportRunDraft draft) async {
    // Reports are generated inside the request; a wide date range on a busy
    // shop outruns the default deadline.
    final response = await _session.post(
      'reports/',
      body: draft.toJson(),
      timeout: PosApiSession.longRunningRequestTimeout,
    );
    _session.ensureSuccess(response, 'Report request failed with status');
    return ReportRun.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
