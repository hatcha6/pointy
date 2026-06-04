import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/printer_config.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/services/print_transport.dart';

enum PrinterTestOutcome { none, success, failed, fakeSuccess, fakeFailed }

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
  }) : _analyticsEngine = analyticsEngine,
       _statusCheckInterval = statusCheckInterval {
    if (autoLoad) {
      loadDefaultConfig();
    }
  }

  final PrintingRepository _repository;
  final AnalyticsEngine? _analyticsEngine;
  final Duration _statusCheckInterval;

  PrinterConfig _config = PrinterConfig.defaultConfig();
  Timer? _statusTimer;
  bool _isLoadingConfig = false;
  bool _isSavingConfig = false;
  bool _isTesting = false;
  bool _isDiscovering = false;
  bool _isCheckingConnection = false;
  bool _isDisposed = false;
  bool _hasConfigLoadError = false;
  bool _hasConfigSaveError = false;
  bool _hasDiscoveryError = false;
  List<PrinterEndpoint> _discoveredPrinters = const [];
  PrinterTestOutcome _testOutcome = PrinterTestOutcome.none;
  PrinterConnectionState _connectionState = PrinterConnectionState.unknown;
  String _connectionMessage = '';
  DateTime? _lastConnectionCheckedAt;

  PrinterConfig get config => _config;
  bool get isLoadingConfig => _isLoadingConfig;
  bool get isSavingConfig => _isSavingConfig;
  bool get isTesting => _isTesting;
  bool get isDiscovering => _isDiscovering;
  bool get isCheckingConnection => _isCheckingConnection;
  bool get hasConfigLoadError => _hasConfigLoadError;
  bool get hasConfigSaveError => _hasConfigSaveError;
  bool get hasDiscoveryError => _hasDiscoveryError;
  List<PrinterEndpoint> get discoveredPrinters => _discoveredPrinters;
  PrinterTestOutcome get testOutcome => _testOutcome;
  PrinterConnectionState get connectionState => _connectionState;
  String get connectionMessage => _connectionMessage;
  DateTime? get lastConnectionCheckedAt => _lastConnectionCheckedAt;
  bool get hasConfiguredPrinter => _hasConfiguredEndpoint(_config.endpoint);
  bool get shouldWarnPrinterDisconnected =>
      hasConfiguredPrinter &&
      _connectionState == PrinterConnectionState.disconnected;

  Future<void> loadDefaultConfig() async {
    _isLoadingConfig = true;
    _hasConfigLoadError = false;
    notifyListeners();

    final result = await _repository.loadDefaultPrinterConfig();
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

  void updateCodeTable(String value) {
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(codeTable: value.trim()),
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
    _testOutcome = PrinterTestOutcome.none;
    notifyListeners();

    final result = await _repository.testPrinter(_config);
    _testOutcome = result.isSuccess
        ? PrinterTestOutcome.success
        : PrinterTestOutcome.failed;
    _updateConnectionStateFromPrintResult(result);
    _trackPrinterTest(result, name: 'printing.printer.tested');
    _isTesting = false;
    notifyListeners();
  }

  Future<void> runFakePrint() async {
    _isTesting = true;
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
    notifyListeners();
  }

  Future<void> _saveDefaultConfig() async {
    _isSavingConfig = true;
    _hasConfigSaveError = false;
    notifyListeners();

    final result = await _repository.saveDefaultPrinterConfig(_config);
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
        'outcome': result.isSuccess ? 'success' : 'failed',
        'source': 'printing_settings',
      },
      metrics: {'timeout_ms': _config.endpoint.timeoutMs},
      flushImmediately: !result.isSuccess,
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
