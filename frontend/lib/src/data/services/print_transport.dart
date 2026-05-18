import '../models/print_job.dart';
import '../models/printer_config.dart';

abstract class PrintTransport {
  const PrintTransport();

  Future<List<PrinterEndpoint>> discover();

  Future<PrintTransportStatus> status(PrinterEndpoint endpoint);

  Future<PrintTransportResult> printJob({
    required PrintJob job,
    required PrinterEndpoint endpoint,
  });

  Future<PrintTransportResult> printBytes({
    required List<int> bytes,
    required PrinterEndpoint endpoint,
  }) async {
    return const PrintTransportResult.failure('raw printing unsupported');
  }

  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint);
}

class PrintTransportStatus {
  const PrintTransportStatus({
    required this.isAvailable,
    required this.message,
  });

  final bool isAvailable;
  final String message;
}

class PrintTransportResult {
  const PrintTransportResult.success(this.message) : isSuccess = true;

  const PrintTransportResult.failure(this.message) : isSuccess = false;

  final bool isSuccess;
  final String message;
}
