import '../models/print_job.dart';
import '../models/printer_config.dart';
import 'print_transport.dart';

class FakePrintTransport extends PrintTransport {
  const FakePrintTransport();

  @override
  Future<List<PrinterEndpoint>> discover() async {
    return const [
      PrinterEndpoint(
        kind: PrintTransportKind.fake,
        name: 'محاكاة الطابعة',
        address: 'fake',
      ),
    ];
  }

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) async {
    return const PrintTransportStatus(
      isAvailable: true,
      message: 'fake transport ready',
    );
  }

  @override
  Future<PrintTransportResult> printJob({
    required PrintJob job,
    required PrinterEndpoint endpoint,
  }) async {
    return PrintTransportResult.success('fake print job ${job.id}');
  }

  @override
  Future<PrintTransportResult> printBytes({
    required List<int> bytes,
    required PrinterEndpoint endpoint,
  }) async {
    return PrintTransportResult.success(
      'fake print sent: ${bytes.length} bytes',
    );
  }

  @override
  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async {
    return const PrintTransportResult.success('fake test print completed');
  }
}
