import '../models/print_job.dart';
import '../models/printer_config.dart';
import 'print_transport.dart';

class SerialPrintTransport extends PrintTransport {
  const SerialPrintTransport();

  @override
  Future<List<PrinterEndpoint>> discover() async => const [];

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) async {
    return const PrintTransportStatus(
      isAvailable: false,
      message: 'serial transport unavailable',
    );
  }

  @override
  Future<PrintTransportResult> printJob({
    required PrintJob job,
    required PrinterEndpoint endpoint,
  }) async {
    return const PrintTransportResult.failure('serial transport unavailable');
  }

  @override
  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async {
    return const PrintTransportResult.failure('serial transport unavailable');
  }
}

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

class WifiPrintTransport extends PrintTransport {
  const WifiPrintTransport();

  @override
  Future<List<PrinterEndpoint>> discover() async => const [];

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) async {
    return const PrintTransportStatus(
      isAvailable: false,
      message: 'network printing unavailable',
    );
  }

  @override
  Future<PrintTransportResult> printJob({
    required PrintJob job,
    required PrinterEndpoint endpoint,
  }) async {
    return const PrintTransportResult.failure('network printing unavailable');
  }

  @override
  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async {
    return const PrintTransportResult.failure('network printing unavailable');
  }
}

class UsbPrintTransport extends PrintTransport {
  const UsbPrintTransport();

  @override
  Future<List<PrinterEndpoint>> discover() async => const [];

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) async {
    return const PrintTransportStatus(
      isAvailable: false,
      message: 'usb printing unavailable',
    );
  }

  @override
  Future<PrintTransportResult> printJob({
    required PrintJob job,
    required PrinterEndpoint endpoint,
  }) async {
    return const PrintTransportResult.failure('usb printing unavailable');
  }

  @override
  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async {
    return const PrintTransportResult.failure('usb printing unavailable');
  }
}
