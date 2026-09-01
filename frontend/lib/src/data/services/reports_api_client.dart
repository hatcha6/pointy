import 'package:http/http.dart' as http;

import '../models/analytics_export.dart';
import '../models/report_catalog.dart';
import '../models/report_run.dart';
import 'analytics_export_receiver.dart';
import 'api_session.dart';

class ReportsApiClient {
  const ReportsApiClient(this._session);

  final PosApiSession _session;

  /// What this user may run, and the period vocabulary the server understands.
  Future<ReportCatalog> fetchCatalog() async {
    final response = await _session.get('reports/catalog/');
    _session.ensureSuccess(response, 'Report catalog failed with status');
    return ReportCatalog.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

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

  /// Past runs, newest first — the archive the app could previously only write.
  Future<List<ReportRunSummary>> fetchHistory({
    ReportRunType? type,
    int limit = 25,
  }) async {
    final response = await _session.get(
      'reports/',
      query: {
        'ordering': '-created_at',
        'page_size': '$limit',
        if (type != null) 'report_type': reportRunTypeToJson(type),
      },
    );
    _session.ensureSuccess(response, 'Report history failed with status');
    final body = _session.decodedBody(response);
    final rows = body is Map ? body['results'] as List? ?? const [] : body as List;
    return [
      for (final row in rows)
        if (row is Map) ReportRunSummary.fromJson(row.cast<String, Object?>()),
    ];
  }

  Future<ReportRun> fetchRun(int id) async {
    final response = await _session.get('reports/$id/');
    _session.ensureSuccess(response, 'Report fetch failed with status');
    return ReportRun.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Re-runs a stored report and reports whether its figures still hold.
  Future<ReportVerification> verifyRun(int id) async {
    final response = await _session.post(
      'reports/$id/verify/',
      timeout: PosApiSession.longRunningRequestTimeout,
    );
    _session.ensureSuccess(response, 'Report verification failed with status');
    return ReportVerification.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Builds the report at export depth and streams it back as CSV.
  ///
  /// Streamed rather than buffered because a detailed export of a busy month is
  /// thousands of rows: the receiver spools it straight to a temp file on
  /// native platforms, so the file never exists whole in app memory.
  Future<AnalyticsExportFile> downloadCsv(ReportRunDraft draft) async {
    final response = await _session.postStreamed(
      'reports/export/',
      body: draft.toJson(),
    );
    await _ensureStreamedSuccess(response);
    return receiveAnalyticsExport(
      response,
      filename: _filenameFor(response, draft),
      contentType: 'text/csv',
    );
  }

  Future<PeriodLockState> fetchPeriodLock() async {
    final response = await _session.get('reports/period-lock/');
    _session.ensureSuccess(response, 'Period lock read failed with status');
    return PeriodLockState.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Closes the books through [lockedThrough], or re-opens when it is null.
  ///
  /// [acknowledged] is required by the server when the date moves *backwards*:
  /// re-opening lets already-reported figures change, which is exactly the
  /// event the lock exists to make visible.
  Future<PeriodLockState> setPeriodLock({
    DateTime? lockedThrough,
    bool includeLockedThrough = true,
    int? fiscalYearStartMonth,
    String note = '',
    bool acknowledged = false,
  }) async {
    final response = await _session.post(
      'reports/period-lock/',
      body: {
        // Sent as an explicit null to re-open; omitted entirely when only the
        // fiscal year is being set, so the lock stays where it is.
        if (includeLockedThrough)
          'locked_through': lockedThrough != null
              ? _apiDate(lockedThrough)
              : null,
        'fiscal_year_start_month': ?fiscalYearStartMonth,
        'note': note,
        'acknowledged': acknowledged,
      },
    );
    _session.ensureSuccess(response, 'Period lock write failed with status');
    return PeriodLockState.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> _ensureStreamedSuccess(http.StreamedResponse response) async {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    // The error body is small; read it so the caller can show the server's own
    // reason rather than a status code.
    final body = await response.stream.bytesToString();
    throw PosApiException(
      message: 'Report export failed with status ${response.statusCode}',
      statusCode: response.statusCode,
      responseBody: body,
    );
  }

  String _filenameFor(http.StreamedResponse response, ReportRunDraft draft) {
    final disposition = response.headers['content-disposition'] ?? '';
    final match = RegExp('filename="([^"]+)"').firstMatch(disposition);
    if (match != null) {
      return match.group(1)!;
    }
    return '${reportRunTypeToJson(draft.reportType)}.csv';
  }

  String _apiDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}
