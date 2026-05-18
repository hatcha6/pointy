import '../models/print_job.dart';
import '../models/printer_config.dart';
import 'api_session.dart';

class PrintingApiClient {
  const PrintingApiClient(this._session);

  final PosApiSession _session;

  Future<List<PrintJob>> fetchPrintJobs({
    PrintJobStatus? status,
    int page = 1,
  }) async {
    final response = await _session.get(
      'print-jobs/',
      query: {
        'page': '$page',
        if (status != null) 'status': _printJobStatusQueryValue(status),
      },
    );
    _session.ensureSuccess(response, 'Print jobs request failed with status');
    return printJobsFromResponse(_session.decodedBody(response));
  }

  Future<PrintJob> claimPrintJob({
    required int jobId,
    required String agentId,
    required PrinterEndpoint endpoint,
  }) async {
    final response = await _session.post(
      'print-jobs/$jobId/claim/',
      body: {'agent_id': agentId, 'printer_endpoint': endpoint.toJson()},
    );
    _session.ensureSuccess(response, 'Print job claim failed with status');
    return PrintJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PrintJob?> claimNextPrintJob({
    required String agentId,
    required PrinterEndpoint endpoint,
  }) async {
    final response = await _session.post(
      'print-jobs/claim-next/',
      body: {'agent_id': agentId, 'printer_endpoint': endpoint.toJson()},
    );
    if (response.statusCode == 204) {
      return null;
    }

    _session.ensureSuccess(response, 'Print job claim-next failed with status');
    return PrintJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PrintJob> reportPrintJob({
    required int jobId,
    required PrintJobReportDraft report,
  }) async {
    final response = await _session.post(
      'print-jobs/$jobId/report/',
      body: report.toJson(),
    );
    _session.ensureSuccess(response, 'Print job report failed with status');
    return PrintJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  String _printJobStatusQueryValue(PrintJobStatus status) {
    return switch (status) {
      PrintJobStatus.pending => 'queued',
      PrintJobStatus.claimed => 'claimed',
      PrintJobStatus.printing => 'printing',
      PrintJobStatus.completed => 'printed',
      PrintJobStatus.failed => 'failed',
      PrintJobStatus.canceled => 'canceled',
    };
  }
}
