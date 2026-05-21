import '../../core/result.dart';
import '../models/report_run.dart';
import '../services/pos_api_service.dart';

class ReportRepository {
  ReportRepository(this._service);

  final PosApiService _service;

  Future<Result<ReportRun>> createReportRun(ReportRunDraft draft) {
    return Result.guard(() => _service.createReportRun(draft));
  }
}
