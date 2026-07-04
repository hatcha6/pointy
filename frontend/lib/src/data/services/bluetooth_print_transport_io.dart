// compat/win8: flutter_bluetooth_classic_serial is DROPPED on this build. It is
// an Android-only plugin (Bluetooth Classic serial has no Windows/desktop
// implementation), a Windows-8 till prints over USB, and — critically — its
// Android plugin definition trips Flutter 3.19's embedding-v2 check during the
// build. Provide the same no-op BluetoothPrintTransport the web stub uses so the
// io export set keeps the symbol without pulling the plugin.
import '../models/print_job.dart';
import '../models/printer_config.dart';
import 'print_transport.dart';

class BluetoothPrintTransport extends PrintTransport {
  const BluetoothPrintTransport();

  @override
  Future<List<PrinterEndpoint>> discover() async => const [];

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) async {
    return const PrintTransportStatus(
      isAvailable: false,
      message: 'bluetooth transport unavailable',
    );
  }

  @override
  Future<PrintTransportResult> printJob({
    required PrintJob job,
    required PrinterEndpoint endpoint,
  }) async {
    return const PrintTransportResult.failure(
      'bluetooth transport unavailable',
    );
  }

  @override
  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async {
    return const PrintTransportResult.failure(
      'bluetooth transport unavailable',
    );
  }
}
