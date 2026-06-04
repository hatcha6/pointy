import '../../core/result.dart';
import '../models/barcode_label.dart';
import '../models/print_job.dart';
import '../models/printer_config.dart';
import '../services/device_settings_storage_service.dart';
import '../services/esc_pos_barcode_label_encoder.dart';
import '../services/pos_api_service.dart';
import '../services/print_transport.dart';
import '../services/print_transports.dart';

class PrintingRepository {
  PrintingRepository(
    this._service, {
    PrintTransport? serialTransport,
    PrintTransport? bluetoothTransport,
    PrintTransport? wifiTransport,
    PrintTransport fakeTransport = const FakePrintTransport(),
    EscPosBarcodeLabelEncoder barcodeLabelEncoder =
        const EscPosBarcodeLabelEncoder(),
    DeviceSettingsStorageService storageService =
        const DeviceSettingsStorageService(),
  }) : _serialTransport = serialTransport ?? SerialPrintTransport(),
       _bluetoothTransport = bluetoothTransport ?? BluetoothPrintTransport(),
       _wifiTransport = wifiTransport ?? WifiPrintTransport(),
       _fakeTransport = fakeTransport,
       _barcodeLabelEncoder = barcodeLabelEncoder,
       _storageService = storageService;

  final PosApiService _service;
  final PrintTransport _serialTransport;
  final PrintTransport _bluetoothTransport;
  final PrintTransport _wifiTransport;
  final PrintTransport _fakeTransport;
  final EscPosBarcodeLabelEncoder _barcodeLabelEncoder;
  final DeviceSettingsStorageService _storageService;

  Future<Result<List<PrintJob>>> loadPrintJobs({
    PrintJobStatus? status,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchPrintJobs(status: status, page: page),
    );
  }

  Future<Result<PrintJob>> claimPrintJob({
    required int jobId,
    required PrinterConfig config,
  }) async {
    return Result.guard(
      () => _service.claimPrintJob(
        jobId: jobId,
        agentId: config.agentId,
        endpoint: config.endpoint,
      ),
    );
  }

  Future<Result<PrintJob?>> claimNextPrintJob(PrinterConfig config) async {
    return Result.guard(
      () => _service.claimNextPrintJob(
        agentId: config.agentId,
        endpoint: config.endpoint,
      ),
    );
  }

  Future<Result<PrintJob>> reportPrintJob({
    required int jobId,
    required PrintJobReportDraft report,
  }) async {
    return Result.guard(
      () => _service.reportPrintJob(jobId: jobId, report: report),
    );
  }

  Future<Result<PrintJob>> printAndReportJob({
    required PrintJob job,
    required PrinterConfig config,
  }) async {
    final printResult = await _transportFor(
      config.endpoint,
    ).printJob(job: job, endpoint: config.endpoint);
    final report = PrintJobReportDraft(
      status: printResult.isSuccess
          ? PrintJobStatus.completed
          : PrintJobStatus.failed,
      agentId: config.agentId,
      message: printResult.message,
      errorMessage: printResult.isSuccess ? null : printResult.message,
      endpoint: config.endpoint,
    );
    return reportPrintJob(jobId: job.id, report: report);
  }

  Future<Result<PrintJob>> requestSaleReprint(int saleOrderId) async {
    return Result.guard(() => _service.requestSaleReprint(saleOrderId));
  }

  Future<Result<List<PrinterEndpoint>>> discoverPrinters() async {
    return Result.guard(() async {
      final discovered = <String, PrinterEndpoint>{};
      for (final transport in [
        _serialTransport,
        _bluetoothTransport,
        _wifiTransport,
      ]) {
        final endpoints = await transport.discover();
        for (final endpoint in endpoints) {
          discovered[_endpointKey(endpoint)] = endpoint;
        }
      }
      return discovered.values.toList(growable: false);
    });
  }

  Future<Result<PrinterConfig>> loadDefaultPrinterConfig() async {
    return loadPrinterConfigForRole(PrinterRole.posReceipt);
  }

  Future<Result<void>> saveDefaultPrinterConfig(PrinterConfig config) async {
    return savePrinterConfigForRole(PrinterRole.posReceipt, config);
  }

  Future<Result<PrinterConfig>> loadPrinterConfigForRole(
    PrinterRole role,
  ) async {
    return Result.guard(() async {
      final config = await _storageService.loadPrinterConfigForRole(role);
      return _devicePrintableConfig(config ?? PrinterConfig.defaultConfig());
    });
  }

  Future<Result<void>> savePrinterConfigForRole(
    PrinterRole role,
    PrinterConfig config,
  ) async {
    return Result.guard(() async {
      await _storageService.savePrinterConfigForRole(
        role,
        _devicePrintableConfig(config),
      );
    });
  }

  Future<PrintTransportStatus> printerStatus(PrinterConfig config) {
    return _transportFor(config.endpoint).status(config.endpoint);
  }

  Future<PrintTransportResult> testPrinter(PrinterConfig config) {
    return _transportFor(config.endpoint).printTest(config.endpoint);
  }

  Future<PrintTransportResult> printFakeReceipt(PrinterConfig config) {
    return _fakeTransport.printTest(config.endpoint);
  }

  Future<PrintTransportResult> printBarcodeLabels(
    List<BarcodeLabelPrintLine> lines,
  ) async {
    if (lines.isEmpty) {
      return const PrintTransportResult.failure('no barcode labels to print');
    }

    final configResult = await loadDefaultPrinterConfig();
    final config = switch (configResult) {
      Ok<PrinterConfig>() => configResult.value,
      Error<PrinterConfig>() => null,
    };
    if (config == null) {
      return const PrintTransportResult.failure('printer config unavailable');
    }

    try {
      final bytes = await _barcodeLabelEncoder.encodeLabels(
        lines: lines,
        endpoint: config.endpoint,
      );
      return _transportFor(
        config.endpoint,
      ).printBytes(bytes: bytes, endpoint: config.endpoint);
    } on Object catch (error) {
      return PrintTransportResult.failure(error.toString());
    }
  }

  PrintTransport _transportFor(PrinterEndpoint endpoint) {
    return switch (endpoint.kind) {
      PrintTransportKind.serial => _serialTransport,
      PrintTransportKind.bluetooth => _bluetoothTransport,
      PrintTransportKind.wifi => _wifiTransport,
      PrintTransportKind.fake => _fakeTransport,
    };
  }

  String _endpointKey(PrinterEndpoint endpoint) {
    return '${endpoint.kind.name}:${endpoint.address}:${endpoint.port}';
  }

  PrinterConfig _devicePrintableConfig(PrinterConfig config) {
    return config.copyWith(isEnabled: true, autoClaimJobs: true);
  }
}
