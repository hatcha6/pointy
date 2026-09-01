import '../../core/result.dart';
import '../models/analytics_export.dart';
import '../models/report_catalog.dart';
import '../models/report_run.dart';
import '../services/pos_api_service.dart';

class ReportRepository {
  ReportRepository(this._service);

  final PosApiService _service;

  Future<Result<ReportCatalog>> loadCatalog() {
    return Result.guard(() => _service.fetchReportCatalog());
  }

  Future<Result<ReportRun>> createReportRun(ReportRunDraft draft) {
    return Result.guard(() => _service.createReportRun(draft));
  }

  Future<Result<List<ReportRunSummary>>> loadHistory({
    ReportRunType? type,
    int limit = 25,
  }) {
    return Result.guard(
      () => _service.fetchReportHistory(type: type, limit: limit),
    );
  }

  Future<Result<ReportRun>> loadRun(int id) {
    return Result.guard(() => _service.fetchReportRun(id));
  }

  Future<Result<ReportVerification>> verifyRun(int id) {
    return Result.guard(() => _service.verifyReportRun(id));
  }

  Future<Result<AnalyticsExportFile>> downloadCsv(ReportRunDraft draft) {
    return Result.guard(() => _service.downloadReportCsv(draft));
  }

  Future<Result<PeriodLockState>> loadPeriodLock() {
    return Result.guard(() => _service.fetchPeriodLock());
  }

  Future<Result<PeriodLockState>> setPeriodLock({
    DateTime? lockedThrough,
    bool includeLockedThrough = true,
    int? fiscalYearStartMonth,
    String note = '',
    bool acknowledged = false,
  }) {
    return Result.guard(
      () => _service.setPeriodLock(
        lockedThrough: lockedThrough,
        includeLockedThrough: includeLockedThrough,
        fiscalYearStartMonth: fiscalYearStartMonth,
        note: note,
        acknowledged: acknowledged,
      ),
    );
  }
}
