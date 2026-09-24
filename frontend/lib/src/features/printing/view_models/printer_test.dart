import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/device_printers.dart';
import '../../../data/models/printer_config.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/services/print_transport.dart';

/// A test print, one per kind of job a printer can do. Each proves the path
/// its job really takes: a label test goes through the label encoder, not
/// the receipt one.
enum PrinterTestKind { receipt, barcodeLabel, document, kitchen }

class PrinterTestResult {
  const PrinterTestResult(this.kind, this.isSuccess);

  final PrinterTestKind kind;
  final bool isSuccess;
}

/// The tests that prove the jobs [printer] does, most important first.
List<PrinterTestKind> printerTestKinds(DevicePrinter printer) {
  return [
    if (printer.holds(PrinterRole.posReceipt)) PrinterTestKind.receipt,
    if (printer.holds(PrinterRole.barcodeLabels)) PrinterTestKind.barcodeLabel,
    if (printer.holds(PrinterRole.documents)) PrinterTestKind.document,
    if (printer.kitchenStationIds.isNotEmpty) PrinterTestKind.kitchen,
  ];
}

/// The one test a printer's card runs: its most important job, or — for a
/// printer with no job yet — whatever its output speaks.
PrinterTestKind primaryTestKind(DevicePrinter printer) {
  final kinds = printerTestKinds(printer);
  if (kinds.isNotEmpty) {
    return kinds.first;
  }
  return printer.endpoint.usesDocumentInvoice
      ? PrinterTestKind.document
      : PrinterTestKind.receipt;
}

/// Runs [kind]'s test on [config]. Never throws.
Future<PrintTransportResult> runPrinterTest(
  PrintingRepository repository,
  PrinterConfig config,
  PrinterTestKind kind,
) async {
  try {
    return await switch (kind) {
      PrinterTestKind.receipt => repository.testPrinter(config),
      PrinterTestKind.barcodeLabel => repository.printBarcodeLabelTest(config),
      PrinterTestKind.document => repository.printDocumentTest(config),
      PrinterTestKind.kitchen => repository.printKitchenTest(config),
    };
  } on Object catch (error) {
    return PrintTransportResult.failure('test print failed: $error');
  }
}

void trackPrinterTest(
  AnalyticsEngine? analyticsEngine, {
  required PrinterTestKind kind,
  required PrinterEndpoint endpoint,
  required PrintTransportResult result,
  required String source,
}) {
  trackAuditEvent(
    analyticsEngine,
    name: 'printing.printer.tested',
    severity: result.isSuccess
        ? AnalyticsEventSeverity.info
        : AnalyticsEventSeverity.warning,
    entityType: 'printer_settings',
    attributes: {
      'test_kind': kind.name,
      'transport_kind': endpoint.kind.name,
      'output_mode': endpoint.outputMode.name,
      'paper_width_mm': endpoint.paperWidthMm,
      'barcode_label_language': endpoint.barcodeLabelLanguage.name,
      'outcome': result.isSuccess ? 'success' : 'failed',
      'source': source,
    },
    metrics: {'timeout_ms': endpoint.timeoutMs},
    flushImmediately: !result.isSuccess,
  );
}
