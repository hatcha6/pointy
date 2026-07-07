import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/printer_config.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/services/print_transport.dart';

enum PrinterTestOutcome {
  none,
  success,
  failed,
  barcodeLabelSuccess,
  barcodeLabelFailed,
  fakeSuccess,
  fakeFailed,
}

enum BarcodeLabelLanguageDetectionOutcome {
  none,
  detected,
  inferred,
  unavailable,
  failed,
}

enum PrinterConnectionState {
  unknown,
  notConfigured,
  checking,
  connected,
  disconnected,
}

class PrintingSettingsViewModel extends ChangeNotifier {
  PrintingSettingsViewModel(
    this._repository, {
    AnalyticsEngine? analyticsEngine,
    Duration statusCheckInterval = const Duration(minutes: 2),
    bool autoLoad = true,
    PrinterRole role = PrinterRole.posReceipt,
    int? stationId,
  }) : _analyticsEngine = analyticsEngine,
       _statusCheckInterval = statusCheckInterval,
       _role = role,
       _stationId = stationId {
    if (autoLoad) {
      loadDefaultConfig();
    }
  }

  final PrintingRepository _repository;
  final AnalyticsEngine? _analyticsEngine;
  final Duration _statusCheckInterval;

  /// Which printer this view model configures. Defaults to the POS receipt
  /// printer; a kitchen target also carries the [PrepStation] id it serves.
  final PrinterRole _role;
  final int? _stationId;

  bool get _isKitchenTarget =>
      _role == PrinterRole.kitchen && _stationId != null;

  PrinterConfig _config = PrinterConfig.defaultConfig();
  Timer? _statusTimer;
  bool _isLoadingConfig = false;
  bool _isSavingConfig = false;
  bool _isTesting = false;
  bool _isTestingBarcodeLabelPrinter = false;
  bool _isDiscovering = false;
  bool _isDetectingBarcodeLabelLanguage = false;
  bool _isCheckingConnection = false;
  bool _isDisposed = false;
  bool _hasConfigLoadError = false;
  bool _hasConfigSaveError = false;
  bool _hasDiscoveryError = false;
  List<PrinterEndpoint> _discoveredPrinters = const [];
  PrinterTestOutcome _testOutcome = PrinterTestOutcome.none;
  BarcodeLabelLanguageDetectionOutcome _barcodeLabelLanguageDetectionOutcome =
      BarcodeLabelLanguageDetectionOutcome.none;
  PrinterConnectionState _connectionState = PrinterConnectionState.unknown;
  String _connectionMessage = '';
  String _barcodeLabelLanguageDetectionMessage = '';
  DateTime? _lastConnectionCheckedAt;

  PrinterConfig get config => _config;
  bool get isLoadingConfig => _isLoadingConfig;
  bool get isSavingConfig => _isSavingConfig;
  bool get isTesting => _isTesting;
  bool get isTestingBarcodeLabelPrinter => _isTestingBarcodeLabelPrinter;
  bool get isDiscovering => _isDiscovering;
  bool get isDetectingBarcodeLabelLanguage => _isDetectingBarcodeLabelLanguage;
  bool get isCheckingConnection => _isCheckingConnection;
  bool get hasConfigLoadError => _hasConfigLoadError;
  bool get hasConfigSaveError => _hasConfigSaveError;
  bool get hasDiscoveryError => _hasDiscoveryError;
  List<PrinterEndpoint> get discoveredPrinters => _discoveredPrinters;
  PrinterTestOutcome get testOutcome => _testOutcome;
  BarcodeLabelLanguageDetectionOutcome
  get barcodeLabelLanguageDetectionOutcome =>
      _barcodeLabelLanguageDetectionOutcome;
  PrinterConnectionState get connectionState => _connectionState;
  String get connectionMessage => _connectionMessage;
  String get barcodeLabelLanguageDetectionMessage =>
      _barcodeLabelLanguageDetectionMessage;
  DateTime? get lastConnectionCheckedAt => _lastConnectionCheckedAt;
  bool get hasConfiguredPrinter => _hasConfiguredEndpoint(_config.endpoint);
  bool get shouldWarnPrinterDisconnected =>
      hasConfiguredPrinter &&
      _connectionState == PrinterConnectionState.disconnected;

  Future<void> loadDefaultConfig() async {
    _isLoadingConfig = true;
    _hasConfigLoadError = false;
    notifyListeners();

    final result = await _loadConfigForTarget();
    switch (result) {
      case Ok<PrinterConfig>():
        _config = result.value;
        _restartConnectionChecks(checkNow: true);
      case Error<PrinterConfig>():
        _hasConfigLoadError = true;
        _stopConnectionChecks();
    }

    _isLoadingConfig = false;
    notifyListeners();
  }

  void updateTransportKind(PrintTransportKind kind) {
    final current = _config.endpoint;
    final endpoint = switch (kind) {
      PrintTransportKind.serial => current.copyWith(
        kind: kind,
        address: current.address.isEmpty
            ? '/dev/tty.usbserial'
            : current.address,
      ),
      PrintTransportKind.bluetooth => current.copyWith(
        kind: kind,
        address: current.address.startsWith('/dev/') ? '' : current.address,
      ),
      PrintTransportKind.wifi => current.copyWith(
        kind: kind,
        address: _looksLikeNetworkHost(current.address) ? current.address : '',
        port: current.port == 0 ? 9100 : current.port,
        outputMode: PrinterOutputMode.escPos,
      ),
      PrintTransportKind.system => current.copyWith(
        kind: kind,
        name: '',
        address: '',
        outputMode: PrinterOutputMode.pdfA4,
      ),
      PrintTransportKind.usb => current.copyWith(
        kind: kind,
        address: current.address.startsWith('/dev/') ? '' : current.address,
        outputMode: PrinterOutputMode.escPos,
      ),
      PrintTransportKind.fake => current.copyWith(kind: kind),
    };
    _updateConfig(_config.copyWith(endpoint: endpoint), checkConnection: true);
  }

  void updatePrinterName(String value) {
    _updateConfig(
      _config.copyWith(endpoint: _config.endpoint.copyWith(name: value)),
      checkConnection: true,
    );
  }

  void updateAddress(String value) {
    _updateConfig(
      _config.copyWith(endpoint: _config.endpoint.copyWith(address: value)),
      checkConnection: true,
    );
  }

  void updateBaudRate(String value) {
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(
          baudRate: int.tryParse(value) ?? _config.endpoint.baudRate,
        ),
      ),
      checkConnection: true,
    );
  }

  void updatePort(String value) {
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(
          port: int.tryParse(value) ?? _config.endpoint.port,
        ),
      ),
      checkConnection: true,
    );
  }

  void updatePaperWidth(String value) {
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(
          paperWidthMm: int.tryParse(value) ?? _config.endpoint.paperWidthMm,
        ),
      ),
    );
  }

  void updatePdfPageSize(PdfPageSize size) {
    _updateConfig(
      _config.copyWith(endpoint: _config.endpoint.copyWith(pdfPageSize: size)),
    );
  }

  void updateCodeTable(String value) {
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(codeTable: value.trim()),
      ),
    );
  }

  void updateCapabilityProfile(String value) {
    final trimmed = value.trim();
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(
          capabilityProfile: trimmed.isEmpty ? 'default' : trimmed,
        ),
      ),
    );
  }

  void updateCutMode(ReceiptCutMode mode) {
    _updateConfig(
      _config.copyWith(endpoint: _config.endpoint.copyWith(cutMode: mode)),
    );
  }

  void updateFeedLines(String value) {
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(
          feedLines: int.tryParse(value) ?? _config.endpoint.feedLines,
        ),
      ),
    );
  }

  void updateBarcodeLabelLanguage(BarcodeLabelPrinterLanguage language) {
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(barcodeLabelLanguage: language),
      ),
    );
  }

  void updateLabelWidth(String value) {
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(
          labelWidthMm: int.tryParse(value) ?? _config.endpoint.labelWidthMm,
        ),
      ),
    );
  }

  void updateLabelHeight(String value) {
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(
          labelHeightMm: int.tryParse(value) ?? _config.endpoint.labelHeightMm,
        ),
      ),
    );
  }

  void updateLabelGap(String value) {
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(
          labelGapMm: int.tryParse(value) ?? _config.endpoint.labelGapMm,
        ),
      ),
    );
  }

  void updateLabelDpi(String value) {
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(
          labelDpi: int.tryParse(value) ?? _config.endpoint.labelDpi,
        ),
      ),
    );
  }

  void updateTimeout(String value) {
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(
          timeoutMs: int.tryParse(value) ?? _config.endpoint.timeoutMs,
        ),
      ),
    );
  }

  void selectDiscoveredPrinter(PrinterEndpoint endpoint) {
    _updateConfig(_config.copyWith(endpoint: endpoint), checkConnection: true);
  }

  void _updateConfig(PrinterConfig config, {bool checkConnection = false}) {
    _config = config.copyWith(isEnabled: true, autoClaimJobs: true);
    _clearTestOutcome();
    if (checkConnection) {
      _restartConnectionChecks(checkNow: true);
    }
    unawaited(_saveDefaultConfig());
  }

  Future<void> discoverPrinters() async {
    _isDiscovering = true;
    _hasDiscoveryError = false;
    notifyListeners();

    final result = await _repository.discoverPrinters();
    switch (result) {
      case Ok<List<PrinterEndpoint>>():
        _discoveredPrinters = result.value;
        _trackPrinterDiscovery(
          success: true,
          discoveredCount: result.value.length,
        );
      case Error<List<PrinterEndpoint>>():
        _hasDiscoveryError = true;
        _trackPrinterDiscovery(success: false, discoveredCount: 0);
    }

    _isDiscovering = false;
    notifyListeners();
  }

  Future<void> testPrinter() async {
    _isTesting = true;
    _isTestingBarcodeLabelPrinter = false;
    _testOutcome = PrinterTestOutcome.none;
    notifyListeners();

    final result = _isKitchenTarget
        ? await _repository.printKitchenTest(_config)
        : await _repository.testPrinter(_config);
    _testOutcome = result.isSuccess
        ? PrinterTestOutcome.success
        : PrinterTestOutcome.failed;
    _updateConnectionStateFromPrintResult(result);
    _trackPrinterTest(result, name: 'printing.printer.tested');
    _isTesting = false;
    notifyListeners();
  }

  Future<void> testBarcodeLabelPrinter() async {
    if (_isTesting || !hasConfiguredPrinter) {
      return;
    }

    _isTesting = true;
    _isTestingBarcodeLabelPrinter = true;
    _testOutcome = PrinterTestOutcome.none;
    notifyListeners();

    final result = await _repository.printBarcodeLabelTest(_config);
    _testOutcome = result.isSuccess
        ? PrinterTestOutcome.barcodeLabelSuccess
        : PrinterTestOutcome.barcodeLabelFailed;
    _updateConnectionStateFromPrintResult(result);
    _trackPrinterTest(result, name: 'printing.printer.barcode_label_tested');
    _isTesting = false;
    _isTestingBarcodeLabelPrinter = false;
    notifyListeners();
  }

  Future<void> detectBarcodeLabelLanguage() async {
    if (_isDetectingBarcodeLabelLanguage || !hasConfiguredPrinter) {
      return;
    }

    _isDetectingBarcodeLabelLanguage = true;
    _barcodeLabelLanguageDetectionOutcome =
        BarcodeLabelLanguageDetectionOutcome.none;
    _barcodeLabelLanguageDetectionMessage = '';
    notifyListeners();

    final result = await _repository.detectBarcodeLabelLanguage(_config);
    switch (result) {
      case Ok():
        final detection = result.value;
        final language = detection.language;
        if (detection.isSuccess && language != null) {
          _config = _config.copyWith(
            endpoint: _config.endpoint.copyWith(barcodeLabelLanguage: language),
          );
          _barcodeLabelLanguageDetectionOutcome = detection.isInferred
              ? BarcodeLabelLanguageDetectionOutcome.inferred
              : BarcodeLabelLanguageDetectionOutcome.detected;
          _barcodeLabelLanguageDetectionMessage = detection.message;
          unawaited(_saveDefaultConfig());
          _trackBarcodeLabelLanguageDetection(success: true);
        } else {
          _barcodeLabelLanguageDetectionOutcome =
              BarcodeLabelLanguageDetectionOutcome.unavailable;
          _barcodeLabelLanguageDetectionMessage = detection.message;
          _trackBarcodeLabelLanguageDetection(success: false);
        }
      case Error():
        _barcodeLabelLanguageDetectionOutcome =
            BarcodeLabelLanguageDetectionOutcome.failed;
        _barcodeLabelLanguageDetectionMessage = result.exception.toString();
        _trackBarcodeLabelLanguageDetection(success: false);
    }

    _isDetectingBarcodeLabelLanguage = false;
    notifyListeners();
  }

  Future<void> runFakePrint() async {
    _isTesting = true;
    _isTestingBarcodeLabelPrinter = false;
    _testOutcome = PrinterTestOutcome.none;
    notifyListeners();

    final PrintTransportResult result = await _repository.printFakeReceipt(
      _config,
    );
    _testOutcome = result.isSuccess
        ? PrinterTestOutcome.fakeSuccess
        : PrinterTestOutcome.fakeFailed;
    _updateConnectionStateFromPrintResult(result);
    _trackPrinterTest(result, name: 'printing.printer.fake_receipt_printed');
    _isTesting = false;
    _isTestingBarcodeLabelPrinter = false;
    notifyListeners();
  }

  Future<void> checkPrinterConnection() async {
    if (_isDisposed || _isCheckingConnection) {
      return;
    }
    if (!hasConfiguredPrinter) {
      _connectionState = PrinterConnectionState.notConfigured;
      _connectionMessage = '';
      _lastConnectionCheckedAt = null;
      _notifyIfActive();
      return;
    }

    _isCheckingConnection = true;
    _connectionState = PrinterConnectionState.checking;
    _notifyIfActive();

    var status = const PrintTransportStatus(
      isAvailable: false,
      message: 'printer status unavailable',
    );
    try {
      status = await _repository.printerStatus(_config);
    } on Object catch (error) {
      status = PrintTransportStatus(
        isAvailable: false,
        message: error.toString(),
      );
    }
    if (_isDisposed) {
      return;
    }
    _connectionState = status.isAvailable
        ? PrinterConnectionState.connected
        : PrinterConnectionState.disconnected;
    _connectionMessage = status.message;
    _lastConnectionCheckedAt = DateTime.now();
    _isCheckingConnection = false;
    _notifyIfActive();
  }

  void _clearTestOutcome() {
    _testOutcome = PrinterTestOutcome.none;
    _barcodeLabelLanguageDetectionOutcome =
        BarcodeLabelLanguageDetectionOutcome.none;
    _barcodeLabelLanguageDetectionMessage = '';
    notifyListeners();
  }

  Future<Result<PrinterConfig>> _loadConfigForTarget() async {
    if (_isKitchenTarget) {
      final config = await _repository.loadKitchenStationConfig(_stationId!);
      return Ok(config ?? PrinterConfig.defaultConfig());
    }
    return _repository.loadDefaultPrinterConfig();
  }

  Future<void> _saveDefaultConfig() async {
    _isSavingConfig = true;
    _hasConfigSaveError = false;
    notifyListeners();

    final result = _isKitchenTarget
        ? await _repository.saveKitchenStationConfig(_stationId!, _config)
        : await _repository.saveDefaultPrinterConfig(_config);
    _isSavingConfig = false;
    _hasConfigSaveError = result is Error<void>;
    notifyListeners();
  }

  bool _looksLikeNetworkHost(String value) {
    return value.contains('.') || value.contains(':');
  }

  void _restartConnectionChecks({required bool checkNow}) {
    _statusTimer?.cancel();
    _statusTimer = null;
    if (!hasConfiguredPrinter) {
      _connectionState = PrinterConnectionState.notConfigured;
      _connectionMessage = '';
      _lastConnectionCheckedAt = null;
      return;
    }
    if (checkNow) {
      unawaited(checkPrinterConnection());
    }
    _statusTimer = Timer.periodic(
      _statusCheckInterval,
      (_) => unawaited(checkPrinterConnection()),
    );
  }

  void _stopConnectionChecks() {
    _statusTimer?.cancel();
    _statusTimer = null;
    _connectionState = PrinterConnectionState.unknown;
    _connectionMessage = '';
    _lastConnectionCheckedAt = null;
  }

  void _updateConnectionStateFromPrintResult(PrintTransportResult result) {
    if (!hasConfiguredPrinter) {
      _connectionState = PrinterConnectionState.notConfigured;
      return;
    }
    _connectionState = result.isSuccess
        ? PrinterConnectionState.connected
        : PrinterConnectionState.disconnected;
    _connectionMessage = result.message;
    _lastConnectionCheckedAt = DateTime.now();
  }

  bool _hasConfiguredEndpoint(PrinterEndpoint endpoint) {
    final name = endpoint.name.trim();
    final address = endpoint.address.trim();
    if (endpoint.kind == PrintTransportKind.system ||
        endpoint.usesDocumentInvoice) {
      return true;
    }
    if (endpoint.kind == PrintTransportKind.fake) {
      return name.isNotEmpty || address.isNotEmpty;
    }
    if (address.isEmpty) {
      return false;
    }
    return endpoint.kind != PrintTransportKind.serial ||
        name.isNotEmpty ||
        address != '/dev/tty.usbserial';
  }

  void _trackPrinterDiscovery({
    required bool success,
    required int discoveredCount,
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: success
          ? 'printing.printer.discovery_completed'
          : 'printing.printer.discovery_failed',
      severity: success
          ? AnalyticsEventSeverity.info
          : AnalyticsEventSeverity.warning,
      entityType: 'printer_settings',
      attributes: {
        'transport_kind': _config.endpoint.kind.name,
        'source': 'printing_settings',
      },
      metrics: {'discovered_count': discoveredCount},
      flushImmediately: !success,
    );
  }

  void _trackPrinterTest(PrintTransportResult result, {required String name}) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      severity: result.isSuccess
          ? AnalyticsEventSeverity.info
          : AnalyticsEventSeverity.warning,
      entityType: 'printer_settings',
      attributes: {
        'transport_kind': _config.endpoint.kind.name,
        'printer_configured': hasConfiguredPrinter,
        'paper_width_mm': _config.endpoint.paperWidthMm,
        'barcode_label_language': _config.endpoint.barcodeLabelLanguage.name,
        'outcome': result.isSuccess ? 'success' : 'failed',
        'source': 'printing_settings',
      },
      metrics: {'timeout_ms': _config.endpoint.timeoutMs},
      flushImmediately: !result.isSuccess,
    );
  }

  void _trackBarcodeLabelLanguageDetection({required bool success}) {
    trackAuditEvent(
      _analyticsEngine,
      name: success
          ? 'printing.barcode_label_language.detected'
          : 'printing.barcode_label_language.detect_failed',
      severity: success
          ? AnalyticsEventSeverity.info
          : AnalyticsEventSeverity.warning,
      entityType: 'printer_settings',
      attributes: {
        'transport_kind': _config.endpoint.kind.name,
        'barcode_label_language': _config.endpoint.barcodeLabelLanguage.name,
        'outcome': _barcodeLabelLanguageDetectionOutcome.name,
        'source': 'printing_settings',
      },
      metrics: {'timeout_ms': _config.endpoint.timeoutMs},
      flushImmediately: !success,
    );
  }

  void _notifyIfActive() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _statusTimer?.cancel();
    super.dispose();
  }
}
