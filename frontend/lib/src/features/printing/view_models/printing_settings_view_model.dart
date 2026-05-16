import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/printer_config.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/services/print_transport.dart';

enum PrinterTestOutcome { none, success, failed, fakeSuccess, fakeFailed }

class PrintingSettingsViewModel extends ChangeNotifier {
  PrintingSettingsViewModel(this._repository) {
    loadDefaultConfig();
  }

  final PrintingRepository _repository;

  PrinterConfig _config = PrinterConfig.defaultConfig();
  bool _isLoadingConfig = false;
  bool _isSavingConfig = false;
  bool _isTesting = false;
  bool _isDiscovering = false;
  bool _hasConfigLoadError = false;
  bool _hasConfigSaveError = false;
  bool _hasDiscoveryError = false;
  List<PrinterEndpoint> _discoveredPrinters = const [];
  PrinterTestOutcome _testOutcome = PrinterTestOutcome.none;

  PrinterConfig get config => _config;
  bool get isLoadingConfig => _isLoadingConfig;
  bool get isSavingConfig => _isSavingConfig;
  bool get isTesting => _isTesting;
  bool get isDiscovering => _isDiscovering;
  bool get hasConfigLoadError => _hasConfigLoadError;
  bool get hasConfigSaveError => _hasConfigSaveError;
  bool get hasDiscoveryError => _hasDiscoveryError;
  List<PrinterEndpoint> get discoveredPrinters => _discoveredPrinters;
  PrinterTestOutcome get testOutcome => _testOutcome;

  Future<void> loadDefaultConfig() async {
    _isLoadingConfig = true;
    _hasConfigLoadError = false;
    notifyListeners();

    final result = await _repository.loadDefaultPrinterConfig();
    switch (result) {
      case Ok<PrinterConfig>():
        _config = result.value;
      case Error<PrinterConfig>():
        _hasConfigLoadError = true;
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
    _updateConfig(_config.copyWith(endpoint: endpoint));
  }

  void updatePrinterName(String value) {
    _updateConfig(
      _config.copyWith(endpoint: _config.endpoint.copyWith(name: value)),
    );
  }

  void updateAddress(String value) {
    _updateConfig(
      _config.copyWith(endpoint: _config.endpoint.copyWith(address: value)),
    );
  }

  void updateBaudRate(String value) {
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(
          baudRate: int.tryParse(value) ?? _config.endpoint.baudRate,
        ),
      ),
    );
  }

  void updatePort(String value) {
    _updateConfig(
      _config.copyWith(
        endpoint: _config.endpoint.copyWith(
          port: int.tryParse(value) ?? _config.endpoint.port,
        ),
      ),
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
    _updateConfig(_config.copyWith(endpoint: endpoint));
  }

  void _updateConfig(PrinterConfig config) {
    _config = config.copyWith(isEnabled: true, autoClaimJobs: true);
    _clearTestOutcome();
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
      case Error<List<PrinterEndpoint>>():
        _hasDiscoveryError = true;
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
    _isTesting = false;
    notifyListeners();
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
}
