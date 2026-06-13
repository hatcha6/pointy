import 'dart:convert';
import 'dart:typed_data';

import '../../core/result.dart';
import '../models/barcode_label.dart';
import '../models/print_audit_event.dart';
import '../models/print_job.dart';
import '../models/printer_config.dart';
import '../models/purchase_submission.dart';
import '../models/sale_order.dart';
import '../models/shop_settings.dart';
import '../services/barcode_label_command_encoder.dart';
import '../services/barcode_label_language_detector.dart';
import '../services/device_settings_storage_service.dart';
import '../services/esc_pos_receipt_encoder.dart';
import '../services/order_document_service.dart';
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
    BarcodeLabelCommandEncoder barcodeLabelEncoder =
        const BarcodeLabelCommandEncoder(),
    BarcodeLabelLanguageDetector barcodeLabelLanguageDetector =
        const BarcodeLabelLanguageDetector(),
    EscPosReceiptEncoder receiptEncoder = const EscPosReceiptEncoder(),
    OrderDocumentService documentService = const OrderDocumentService(),
    DeviceSettingsStorageService storageService =
        const DeviceSettingsStorageService(),
  }) : _serialTransport = serialTransport ?? SerialPrintTransport(),
       _bluetoothTransport = bluetoothTransport ?? BluetoothPrintTransport(),
       _wifiTransport = wifiTransport ?? WifiPrintTransport(),
       _fakeTransport = fakeTransport,
       _barcodeLabelEncoder = barcodeLabelEncoder,
       _barcodeLabelLanguageDetector = barcodeLabelLanguageDetector,
       _receiptEncoder = receiptEncoder,
       _documentService = documentService,
       _storageService = storageService;

  final PosApiService _service;
  final PrintTransport _serialTransport;
  final PrintTransport _bluetoothTransport;
  final PrintTransport _wifiTransport;
  final PrintTransport _fakeTransport;
  final BarcodeLabelCommandEncoder _barcodeLabelEncoder;
  final BarcodeLabelLanguageDetector _barcodeLabelLanguageDetector;
  final EscPosReceiptEncoder _receiptEncoder;
  final OrderDocumentService _documentService;
  final DeviceSettingsStorageService _storageService;

  Future<Result<List<PrintJob>>> loadPrintJobs({
    PrintJobStatus? status,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchPrintJobs(status: status, page: page),
    );
  }

  Future<Result<List<PrintAuditEvent>>> loadPrintAuditEvents({
    required PrintAuditDocumentType documentType,
    required int documentId,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchPrintAuditEvents(
        documentType: documentType,
        documentId: documentId,
        page: page,
      ),
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

  Future<Result<PrintJob>> requeuePrintJob(int jobId) async {
    return Result.guard(() => _service.requeuePrintJob(jobId));
  }

  Future<Result<PrintJob>> printAndReportJob({
    required PrintJob job,
    required PrinterConfig config,
    bool requeueOnFailure = false,
  }) async {
    if (config.endpoint.usesDocumentInvoice) {
      return Error(Exception('document printers require order-level printing'));
    }
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
    final reportResult = await reportPrintJob(jobId: job.id, report: report);
    if (printResult.isSuccess) {
      return reportResult;
    }

    if (requeueOnFailure && reportResult is Ok<PrintJob>) {
      await requeuePrintJob(job.id);
    }
    return Error(Exception(printResult.message));
  }

  Future<Result<PrintJob>> requestSaleReprint(int saleOrderId) async {
    return Result.guard(() => _service.requestSaleReprint(saleOrderId));
  }

  Future<Result<List<PrinterEndpoint>>> discoverPrinters() async {
    return Result.guard(() async {
      final discovered = <String, PrinterEndpoint>{};
      for (final endpoint
          in await _documentService.discoverDocumentPrinters()) {
        discovered[_endpointKey(endpoint)] = endpoint;
      }
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

  /// The kitchen station printers this device serves, keyed by prep station id.
  Future<Map<int, PrinterConfig>> loadKitchenStationConfigs() async {
    final configs = await _storageService.loadKitchenStationConfigs();
    return configs.map(
      (stationId, config) =>
          MapEntry(stationId, _devicePrintableConfig(config)),
    );
  }

  Future<PrinterConfig?> loadKitchenStationConfig(int stationId) async {
    final config = await _storageService.loadKitchenStationConfig(stationId);
    return config == null ? null : _devicePrintableConfig(config);
  }

  Future<Result<void>> saveKitchenStationConfig(
    int stationId,
    PrinterConfig config,
  ) async {
    return Result.guard(() async {
      await _storageService.saveKitchenStationConfig(
        stationId,
        _devicePrintableConfig(config),
      );
    });
  }

  Future<Result<void>> removeKitchenStationConfig(int stationId) async {
    return Result.guard(
      () => _storageService.removeKitchenStationConfig(stationId),
    );
  }

  /// Claims a queued kitchen job for this device's station printer, then prints
  /// and reports it. A job must be claimed before the backend accepts a
  /// printed/failed report, so the two steps are sequenced here.
  Future<Result<PrintJob>> claimAndPrintKitchenJob({
    required PrintJob job,
    required PrinterConfig config,
  }) async {
    final claimResult = await claimPrintJob(jobId: job.id, config: config);
    return switch (claimResult) {
      Ok<PrintJob>(value: final claimed) => await printAndReportJob(
        job: claimed,
        config: config,
        requeueOnFailure: true,
      ),
      Error<PrintJob>(:final exception) => Error(exception),
    };
  }

  Future<PrintTransportStatus> printerStatus(PrinterConfig config) {
    if (config.endpoint.usesDocumentInvoice) {
      return _documentService.printerStatus(config.endpoint);
    }
    return _transportFor(config.endpoint).status(config.endpoint);
  }

  Future<PrintTransportResult> testPrinter(PrinterConfig config) {
    if (config.endpoint.usesDocumentInvoice) {
      return _documentService.printTest(config.endpoint);
    }
    return _transportFor(config.endpoint).printTest(config.endpoint);
  }

  Future<PrintTransportResult> printFakeReceipt(PrinterConfig config) {
    return _fakeTransport.printTest(config.endpoint);
  }

  /// Prints a sample kitchen chit so a station's thermal printer can be tested
  /// from settings without ringing up a sale.
  Future<PrintTransportResult> printKitchenTest(PrinterConfig config) async {
    if (config.endpoint.usesDocumentInvoice) {
      return const PrintTransportResult.failure(
        'document printers do not print kitchen tickets',
      );
    }
    if (!config.endpoint.usesThermalReceipt) {
      return const PrintTransportResult.failure(
        'kitchen tickets require a thermal printer',
      );
    }
    try {
      final bytes = await _receiptEncoder.encodeKitchenTest(config.endpoint);
      return _transportFor(
        config.endpoint,
      ).printBytes(bytes: bytes, endpoint: config.endpoint);
    } on Object catch (error) {
      return PrintTransportResult.failure('kitchen test print failed: $error');
    }
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
    if (!config.endpoint.usesThermalReceipt) {
      return const PrintTransportResult.failure(
        'barcode labels require a thermal printer',
      );
    }

    try {
      return _printBarcodeLabelLines(lines, config);
    } on Object catch (error) {
      return PrintTransportResult.failure(error.toString());
    }
  }

  Future<PrintTransportResult> printBarcodeLabelTest(
    PrinterConfig config,
  ) async {
    if (config.endpoint.usesDocumentInvoice) {
      return const PrintTransportResult.failure(
        'document printers do not print barcode labels',
      );
    }
    if (!config.endpoint.usesThermalReceipt) {
      return const PrintTransportResult.failure(
        'barcode labels require a thermal printer',
      );
    }

    try {
      return _printBarcodeLabelLines(const [
        BarcodeLabelPrintLine(
          label: BarcodeLabelDraft(
            displayName: 'ملصق اختبار',
            productName: 'ملصق اختبار',
            sku: 'TEST-LABEL',
            barcode: '123456789012',
            unitPrice: 1,
          ),
          copies: 1,
          includePrice: true,
        ),
      ], config);
    } on Object catch (error) {
      return PrintTransportResult.failure(error.toString());
    }
  }

  Future<Result<BarcodeLabelLanguageDetectionResult>>
  detectBarcodeLabelLanguage(PrinterConfig config) async {
    if (config.endpoint.usesDocumentInvoice) {
      return Error(Exception('document printers do not print barcode labels'));
    }
    return Result.guard(
      () => _barcodeLabelLanguageDetector.detect(
        endpoint: config.endpoint,
        transport: _transportFor(config.endpoint),
      ),
    );
  }

  Future<PrintTransportResult> printSaleInvoice({
    required SaleOrder order,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
  }) async {
    final configResult = await loadDefaultPrinterConfig();
    final config = switch (configResult) {
      Ok<PrinterConfig>() => configResult.value,
      Error<PrinterConfig>() => null,
    };
    if (config == null) {
      return const PrintTransportResult.failure('printer config unavailable');
    }

    if (config.endpoint.usesDocumentInvoice) {
      final auditEvent = await _beginPrintAudit(
        documentType: PrintAuditDocumentType.saleOrder,
        documentId: order.id,
        action: PrintAuditAction.print,
        config: config,
      );
      if (auditEvent == null) {
        return const PrintTransportResult.failure('print audit unavailable');
      }
      final result = await _printDocument(() {
        return _documentService.printSaleInvoice(
          order: order,
          shopSettings: shopSettings,
          shopLogoBytes: shopLogoBytes,
          endpoint: config.endpoint,
        );
      });
      await _reportPrintAudit(
        auditEvent,
        _auditStatusForPrintResult(result),
        message: result.message,
      );
      return result;
    }

    final jobResult = await requestSaleReprint(order.id);
    switch (jobResult) {
      case Ok<PrintJob>(value: final printJob):
        final result = await printAndReportJob(job: printJob, config: config);
        return switch (result) {
          Ok<PrintJob>() => const PrintTransportResult.success(
            'sale invoice printed',
          ),
          Error<PrintJob>(:final exception) => PrintTransportResult.failure(
            exception.toString(),
          ),
        };
      case Error<PrintJob>(:final exception):
        return PrintTransportResult.failure(
          'sale print audit unavailable: $exception',
        );
    }
  }

  Future<PrintTransportResult> printPurchaseOrder({
    required PurchaseOrder order,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
  }) async {
    final configResult = await loadDefaultPrinterConfig();
    final config = switch (configResult) {
      Ok<PrinterConfig>() => configResult.value,
      Error<PrinterConfig>() => null,
    };
    if (config == null) {
      return const PrintTransportResult.failure('printer config unavailable');
    }

    final auditEvent = await _beginPrintAudit(
      documentType: PrintAuditDocumentType.purchaseOrder,
      documentId: order.id,
      action: PrintAuditAction.print,
      config: config,
    );
    if (auditEvent == null) {
      return const PrintTransportResult.failure('print audit unavailable');
    }

    final result = config.endpoint.usesDocumentInvoice
        ? await _printDocument(() {
            return _documentService.printPurchaseOrder(
              order: order,
              shopSettings: shopSettings,
              shopLogoBytes: shopLogoBytes,
              endpoint: config.endpoint,
            );
          })
        : await _printThermalPayload(
            _purchaseReceiptPayload(
              order: order,
              shopSettings: shopSettings,
              shopLogoBytes: shopLogoBytes,
            ),
            config,
          );
    await _reportPrintAudit(
      auditEvent,
      _auditStatusForPrintResult(result),
      message: result.message,
    );
    return result;
  }

  Future<OrderDocumentActionStatus> shareSaleInvoice({
    required SaleOrder order,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
  }) async {
    final auditEvent = await _beginShareAudit(
      documentType: PrintAuditDocumentType.saleOrder,
      documentId: order.id,
    );
    if (auditEvent == null) {
      return OrderDocumentActionStatus.failed;
    }
    final status = await _documentService.shareSaleInvoice(
      order: order,
      shopSettings: shopSettings,
      shopLogoBytes: shopLogoBytes,
    );
    await _reportPrintAudit(auditEvent, _auditStatusForDocumentAction(status));
    return status;
  }

  Future<OrderDocumentActionStatus> sharePurchaseOrder({
    required PurchaseOrder order,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
  }) async {
    final auditEvent = await _beginShareAudit(
      documentType: PrintAuditDocumentType.purchaseOrder,
      documentId: order.id,
    );
    if (auditEvent == null) {
      return OrderDocumentActionStatus.failed;
    }
    final status = await _documentService.sharePurchaseOrder(
      order: order,
      shopSettings: shopSettings,
      shopLogoBytes: shopLogoBytes,
    );
    await _reportPrintAudit(auditEvent, _auditStatusForDocumentAction(status));
    return status;
  }

  Future<PrintAuditEvent?> _beginPrintAudit({
    required PrintAuditDocumentType documentType,
    required int documentId,
    required PrintAuditAction action,
    required PrinterConfig config,
  }) {
    return _recordPrintAuditEvent(
      PrintAuditEventDraft(
        documentType: documentType,
        documentId: documentId,
        action: action,
        agentId: config.agentId,
        printerEndpoint: config.endpoint.toJson(),
        deviceName: config.agentId,
        printerName: _endpointDisplayName(config.endpoint),
        metadata: {
          'output_mode': config.endpoint.outputMode.name,
          'transport_kind': config.endpoint.kind.name,
        },
      ),
    );
  }

  Future<PrintAuditEvent?> _beginShareAudit({
    required PrintAuditDocumentType documentType,
    required int documentId,
  }) async {
    final config = await _loadAuditPrinterConfig();
    final deliveryChannel = _documentService.deliveryChannel;
    return _recordPrintAuditEvent(
      PrintAuditEventDraft(
        documentType: documentType,
        documentId: documentId,
        action: PrintAuditAction.share,
        agentId: config.agentId,
        printerEndpoint: {
          'kind': deliveryChannel,
          'name': 'PDF',
          'output_mode': PrinterOutputMode.pdfA4.name,
        },
        deviceName: config.agentId,
        printerName: 'PDF',
        metadata: {
          'delivery_channel': deliveryChannel,
          'default_printer_endpoint': config.endpoint.toJson(),
        },
      ),
    );
  }

  Future<PrinterConfig> _loadAuditPrinterConfig() async {
    final result = await loadDefaultPrinterConfig();
    return switch (result) {
      Ok<PrinterConfig>(value: final config) => config,
      Error<PrinterConfig>() => PrinterConfig.defaultConfig(),
    };
  }

  Future<PrintAuditEvent?> _recordPrintAuditEvent(
    PrintAuditEventDraft draft,
  ) async {
    try {
      return _service.recordPrintAuditEvent(draft);
    } on Exception {
      return null;
    }
  }

  Future<void> _reportPrintAudit(
    PrintAuditEvent auditEvent,
    PrintAuditStatus status, {
    String message = '',
  }) async {
    try {
      await _service.reportPrintAuditEvent(
        eventId: auditEvent.id,
        report: PrintAuditEventReportDraft(status: status, message: message),
      );
    } on Exception {
      return;
    }
  }

  PrintAuditStatus _auditStatusForPrintResult(PrintTransportResult result) {
    if (result.isSuccess) {
      return PrintAuditStatus.completed;
    }
    final normalizedMessage = result.message.toLowerCase();
    if (normalizedMessage.contains('cancel')) {
      return PrintAuditStatus.canceled;
    }
    return PrintAuditStatus.failed;
  }

  PrintAuditStatus _auditStatusForDocumentAction(
    OrderDocumentActionStatus status,
  ) {
    return switch (status) {
      OrderDocumentActionStatus.completed => PrintAuditStatus.completed,
      OrderDocumentActionStatus.canceled => PrintAuditStatus.canceled,
      OrderDocumentActionStatus.failed => PrintAuditStatus.failed,
    };
  }

  String _endpointDisplayName(PrinterEndpoint endpoint) {
    final name = endpoint.name.trim();
    if (name.isNotEmpty) {
      return name;
    }
    final address = endpoint.address.trim();
    if (address.isNotEmpty) {
      return address;
    }
    return endpoint.kind.name;
  }

  PrintTransport _transportFor(PrinterEndpoint endpoint) {
    return switch (endpoint.kind) {
      PrintTransportKind.serial => _serialTransport,
      PrintTransportKind.bluetooth => _bluetoothTransport,
      PrintTransportKind.wifi => _wifiTransport,
      PrintTransportKind.system => throw StateError(
        'system printers use document printing',
      ),
      PrintTransportKind.fake => _fakeTransport,
    };
  }

  Future<BarcodeLabelPrinterLanguage> _resolveBarcodeLabelLanguage(
    PrinterEndpoint endpoint,
  ) async {
    final configured = endpoint.barcodeLabelLanguage;
    if (configured != BarcodeLabelPrinterLanguage.auto) {
      return configured;
    }
    try {
      final detection = await _barcodeLabelLanguageDetector.detect(
        endpoint: endpoint,
        transport: _transportFor(endpoint),
      );
      return detection.language ?? BarcodeLabelPrinterLanguage.zpl;
    } on Object {
      return BarcodeLabelPrinterLanguage.zpl;
    }
  }

  String _endpointKey(PrinterEndpoint endpoint) {
    return '${endpoint.kind.name}:${endpoint.outputMode.name}:${endpoint.address}:${endpoint.port}';
  }

  PrinterConfig _devicePrintableConfig(PrinterConfig config) {
    return config.copyWith(isEnabled: true, autoClaimJobs: true);
  }

  Future<PrintTransportResult> _printDocument(
    Future<bool> Function() printDocument,
  ) async {
    try {
      final printed = await printDocument();
      return printed
          ? const PrintTransportResult.success('document print sent')
          : const PrintTransportResult.failure('document print canceled');
    } on Object catch (error) {
      return PrintTransportResult.failure('document print failed: $error');
    }
  }

  Future<PrintTransportResult> _printThermalPayload(
    Map<String, Object?> payload,
    PrinterConfig config,
  ) async {
    try {
      final bytes = await _receiptEncoder.encodePayload(
        payload: payload,
        endpoint: config.endpoint,
      );
      return _transportFor(
        config.endpoint,
      ).printBytes(bytes: bytes, endpoint: config.endpoint);
    } on Object catch (error) {
      return PrintTransportResult.failure('thermal print failed: $error');
    }
  }

  Future<PrintTransportResult> _printBarcodeLabelLines(
    List<BarcodeLabelPrintLine> lines,
    PrinterConfig config,
  ) async {
    final language = await _resolveBarcodeLabelLanguage(config.endpoint);
    final bytes = await _barcodeLabelEncoder.encodeLabels(
      lines: lines,
      endpoint: config.endpoint,
      language: language,
    );
    return _transportFor(
      config.endpoint,
    ).printBytes(bytes: bytes, endpoint: config.endpoint);
  }

  Map<String, Object?> _purchaseReceiptPayload({
    required PurchaseOrder order,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
  }) {
    return {
      'shop': _shopPayload(shopSettings, logoBytes: shopLogoBytes),
      'order': {
        'document_title': 'فاتورة مشتريات',
        'total_label': 'الإجمالي',
        'receipt_number': _purchaseReference(order),
        if (order.createdAt != null) 'created_at': order.createdAt!.toString(),
        'total': order.total.toStringAsFixed(2),
        'lines': [
          for (final line in order.lines)
            {
              'name': line.displayName.trim().isEmpty
                  ? 'منتج'
                  : line.displayName.trim(),
              'quantity': line.quantity,
              'unit_price': line.unitCost.toStringAsFixed(2),
              'line_total': (line.landedLineTotal ?? line.total)
                  .toStringAsFixed(2),
            },
        ],
      },
    };
  }

  Map<String, Object?> _shopPayload(
    ShopSettings? settings, {
    Uint8List? logoBytes,
  }) {
    return {
      'name': settings?.shopName.trim().isNotEmpty == true
          ? settings!.shopName.trim()
          : 'نقطة البيع',
      if (settings?.receiptHeader.trim().isNotEmpty == true)
        'receipt_header': settings!.receiptHeader.trim(),
      if (settings?.receiptFooter.trim().isNotEmpty == true)
        'receipt_footer': settings!.receiptFooter.trim(),
      if (logoBytes != null && logoBytes.isNotEmpty)
        'logo_bytes': base64Encode(logoBytes),
    };
  }

  String _purchaseReference(PurchaseOrder order) {
    final orderNumber = order.orderNumber.trim();
    return orderNumber.isEmpty ? '${order.id}' : orderNumber;
  }
}
