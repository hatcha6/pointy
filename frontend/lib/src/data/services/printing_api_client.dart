import '../models/print_audit_event.dart';
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

  Future<PrintJob> requeuePrintJob({required int jobId}) async {
    final response = await _session.post('print-jobs/$jobId/requeue/');
    _session.ensureSuccess(response, 'Print job requeue failed with status');
    return PrintJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<PrintAuditEvent>> fetchPrintAuditEvents({
    required PrintAuditDocumentType documentType,
    required int documentId,
    PrintAuditPaymentKind? paymentKind,
    int page = 1,
  }) async {
    final documentField = switch (documentType) {
      PrintAuditDocumentType.saleOrder => 'sale_order',
      PrintAuditDocumentType.purchaseOrder => 'purchase_order',
      // Payment receipts are filtered by the money table the proof points at:
      // a customer money-IN [Payment] (`payment`) or a supplier money-OUT
      // SupplierPayment (`supplier_payment`). Defaults to the customer FK.
      PrintAuditDocumentType.paymentReceipt =>
        paymentKind == PrintAuditPaymentKind.supplier
            ? 'supplier_payment'
            : 'payment',
    };
    final response = await _session.get(
      'print-audit-events/',
      query: {
        'page': '$page',
        'document_type': printAuditDocumentTypeToJson(documentType),
        documentField: '$documentId',
      },
    );
    _session.ensureSuccess(
      response,
      'Print audit events request failed with status',
    );
    return printAuditEventsFromResponse(_session.decodedBody(response));
  }

  Future<PrintAuditEvent> recordPrintAuditEvent(
    PrintAuditEventDraft draft,
  ) async {
    final response = await _session.post(
      'print-audit-events/record/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Print audit event record failed with status',
    );
    return PrintAuditEvent.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PrintAuditEvent> reportPrintAuditEvent({
    required int eventId,
    required PrintAuditEventReportDraft report,
  }) async {
    final response = await _session.post(
      'print-audit-events/$eventId/report/',
      body: report.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Print audit event report failed with status',
    );
    return PrintAuditEvent.fromJson(
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
