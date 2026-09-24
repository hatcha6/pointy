import '../models/device_printers.dart';
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

  Future<PrintTransportResponse> sendAndReceiveBytes({
    required List<int> bytes,
    required PrinterEndpoint endpoint,
    Duration? readTimeout,
  }) async {
    return const PrintTransportResponse.failure(
      'printer response probes unsupported',
    );
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
  const PrintTransportResult.success(this.message)
    : isSuccess = true,
      unassignedRole = null;

  const PrintTransportResult.failure(this.message)
    : isSuccess = false,
      unassignedRole = null;

  /// Nothing was sent, because no printer on this device does [role]'s job.
  PrintTransportResult.unassigned(PrinterRole role)
    : isSuccess = false,
      unassignedRole = role,
      message = PrinterRoleUnassigned(role).toString();

  final bool isSuccess;
  final String message;

  /// Set when the print never reached a printer because none holds the job:
  /// something only the device's printer settings can fix, unlike a printer
  /// that is switched off.
  final PrinterRole? unassignedRole;
}

class PrintTransportResponse {
  const PrintTransportResponse.success(this.bytes, this.message)
    : isSuccess = true;

  const PrintTransportResponse.failure(this.message)
    : isSuccess = false,
      bytes = const [];

  final bool isSuccess;
  final String message;
  final List<int> bytes;

  String get text => String.fromCharCodes(bytes);
}
