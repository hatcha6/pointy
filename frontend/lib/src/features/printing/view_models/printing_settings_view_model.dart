import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/device_printers.dart';
import '../../../data/models/prep_station.dart';
import '../../../data/models/printer_config.dart';
import '../../../data/repositories/prep_station_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import 'printer_test.dart';

export 'printer_test.dart';

enum PrinterConnectionState {
  unknown,
  notConfigured,
  checking,
  connected,
  disconnected,
}

enum KitchenStationsState { idle, loading, loaded, failed, unavailable }

/// The printers on this device, the job each one does, and whether each is
/// answering.
///
/// Lives for the whole app, not just the settings screen: it also watches the
/// receipt printer in the background, because a receipt printer that went
/// dark is worth saying out loud before the next sale rather than after it.
class PrintingSettingsViewModel extends ChangeNotifier {
  PrintingSettingsViewModel(
    this._repository, {
    PrepStationRepository? prepStationRepository,
    AnalyticsEngine? analyticsEngine,
    Duration statusCheckInterval = const Duration(minutes: 2),
    bool autoLoad = true,
  }) : _prepStationRepository = prepStationRepository,
       _analyticsEngine = analyticsEngine,
       _statusCheckInterval = statusCheckInterval {
    if (autoLoad) {
      unawaited(load());
    }
  }

  final PrintingRepository _repository;
  final PrepStationRepository? _prepStationRepository;
  final AnalyticsEngine? _analyticsEngine;
  final Duration _statusCheckInterval;

  DevicePrinters _printers = DevicePrinters.empty;
  bool _isLoading = false;
  bool _hasLoadError = false;
  bool _isSaving = false;
  bool _hasSaveError = false;
  bool _isDisposed = false;
  Timer? _receiptWatch;
  Future<void> _writes = Future<void>.value();

  final Map<String, PrinterConnectionState> _connection = {};
  final Map<String, PrinterTestResult> _testResults = {};
  final Set<String> _testing = {};

  List<PrinterEndpoint> _discoveredPrinters = const [];
  bool _isDiscovering = false;
  bool _hasDiscoveryError = false;

  List<PrepStation> _kitchenStations = const [];
  KitchenStationsState _kitchenStationsState = KitchenStationsState.idle;

  PrintingRepository get repository => _repository;
  AnalyticsEngine? get analyticsEngine => _analyticsEngine;

  DevicePrinters get printers => _printers;
  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;
  bool get isSaving => _isSaving;
  bool get hasSaveError => _hasSaveError;

  DevicePrinter? holderOf(PrinterRole role) => _printers.holderOf(role);
  DevicePrinter? kitchenPrinterFor(int stationId) =>
      _printers.kitchenPrinterFor(stationId);
  DevicePrinter? get receiptPrinter => holderOf(PrinterRole.posReceipt);

  List<PrinterEndpoint> get discoveredPrinters => _discoveredPrinters;
  bool get isDiscovering => _isDiscovering;
  bool get hasDiscoveryError => _hasDiscoveryError;

  /// The shop's active prep stations, when this user may see them.
  List<PrepStation> get kitchenStations => _kitchenStations;
  KitchenStationsState get kitchenStationsState => _kitchenStationsState;

  PrinterConnectionState connectionOf(String printerId) =>
      _connection[printerId] ?? PrinterConnectionState.unknown;

  bool isTesting(String printerId) => _testing.contains(printerId);

  PrinterTestResult? testResultOf(String printerId) => _testResults[printerId];

  /// The receipt printer's health, for the app-wide "printer disconnected"
  /// warning.
  PrinterConnectionState get connectionState {
    final receipt = receiptPrinter;
    return receipt == null
        ? PrinterConnectionState.notConfigured
        : connectionOf(receipt.id);
  }

  bool get shouldWarnPrinterDisconnected =>
      receiptPrinter != null &&
      connectionState == PrinterConnectionState.disconnected;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    _notify();

    final result = await _repository.loadDevicePrinters();
    switch (result) {
      case Ok<DevicePrinters>(:final value):
        _printers = value;
        _forgetRemovedPrinters();
        _watchReceiptPrinter(checkNow: true);
      case Error<DevicePrinters>():
        _hasLoadError = true;
        _receiptWatch?.cancel();
    }

    _isLoading = false;
    _notify();
  }

  /// Adds [printer] or saves changes to it. The jobs it claims move to it
  /// from whichever printer had them.
  Future<bool> savePrinter(DevicePrinter printer) async {
    final saved = await _commit((printers) => printers.upsert(printer));
    if (saved) {
      unawaited(checkConnection(printer.id));
    }
    return saved;
  }

  Future<bool> removePrinter(String printerId) {
    return _commit((printers) => printers.remove(printerId));
  }

  /// Hands [role] to the printer with [printerId], or to none when null.
  Future<bool> assignRole(PrinterRole role, String? printerId) {
    return _commit((printers) => printers.assignRole(role, printerId));
  }

  Future<bool> assignKitchenStation(int stationId, String? printerId) {
    return _commit(
      (printers) => printers.assignKitchenStation(stationId, printerId),
    );
  }

  Future<void> checkConnection(String printerId) async {
    final printer = _printers.byId(printerId);
    if (_isDisposed ||
        printer == null ||
        connectionOf(printerId) == PrinterConnectionState.checking) {
      return;
    }
    _connection[printerId] = PrinterConnectionState.checking;
    _notify();

    var available = false;
    try {
      available = (await _repository.printerStatus(printer.config)).isAvailable;
    } on Object {
      available = false;
    }
    if (_isDisposed) {
      return;
    }
    // The printer may have been removed, or pointed elsewhere, while it was
    // being asked: an answer about the old device must not land on the new
    // one, which gets asked in its own right.
    final current = _printers.byId(printerId);
    if (!_sameDevice(current?.endpoint, printer.endpoint)) {
      _connection.remove(printerId);
      _notify();
      if (current != null) {
        unawaited(checkConnection(printerId));
      }
      return;
    }
    _connection[printerId] = available
        ? PrinterConnectionState.connected
        : PrinterConnectionState.disconnected;
    _notify();
  }

  Future<void> checkAllConnections() async {
    await Future.wait([
      for (final printer in _printers.printers) checkConnection(printer.id),
    ]);
  }

  /// Checks the receipt printer, the one the till cannot sell well without.
  Future<void> checkPrinterConnection() async {
    final receipt = receiptPrinter;
    if (receipt != null) {
      await checkConnection(receipt.id);
    }
  }

  /// Prints a test of the first job the printer does, so a tap on its card
  /// proves the thing it is there for.
  Future<void> testPrinter(String printerId) async {
    final printer = _printers.byId(printerId);
    if (printer == null || _testing.contains(printerId)) {
      return;
    }
    final kind = primaryTestKind(printer);
    _testing.add(printerId);
    _testResults.remove(printerId);
    _notify();

    final result = await runPrinterTest(_repository, printer.config, kind);
    _testing.remove(printerId);
    _testResults[printerId] = PrinterTestResult(kind, result.isSuccess);
    if (_printers.byId(printerId) != null) {
      _connection[printerId] = result.isSuccess
          ? PrinterConnectionState.connected
          : PrinterConnectionState.disconnected;
    }
    trackPrinterTest(
      _analyticsEngine,
      kind: kind,
      endpoint: printer.endpoint,
      result: result,
      source: 'printer_card',
    );
    _notify();
  }

  Future<void> discoverPrinters() async {
    if (_isDiscovering) {
      return;
    }
    _isDiscovering = true;
    _hasDiscoveryError = false;
    _notify();

    final result = await _repository.discoverPrinters();
    switch (result) {
      case Ok<List<PrinterEndpoint>>(:final value):
        _discoveredPrinters = value;
        _trackDiscovery(success: true, discoveredCount: value.length);
      case Error<List<PrinterEndpoint>>():
        _hasDiscoveryError = true;
        _trackDiscovery(success: false, discoveredCount: 0);
    }

    _isDiscovering = false;
    _notify();
  }

  /// Loads the prep stations whose chits this device could print. [allowed]
  /// is the user's permission: asking without it only earns a 403.
  Future<void> loadKitchenStations({required bool allowed}) async {
    final repository = _prepStationRepository;
    if (!allowed || repository == null) {
      _kitchenStations = const [];
      _kitchenStationsState = KitchenStationsState.unavailable;
      _notify();
      return;
    }
    if (_kitchenStationsState == KitchenStationsState.loading) {
      return;
    }
    _kitchenStationsState = KitchenStationsState.loading;
    _notify();

    final result = await repository.loadStations();
    switch (result) {
      case Ok<List<PrepStation>>(:final value):
        _kitchenStations = [
          for (final station in value)
            if (station.isActive) station,
        ];
        _kitchenStationsState = KitchenStationsState.loaded;
      case Error<List<PrepStation>>():
        _kitchenStationsState = KitchenStationsState.failed;
    }
    _notify();
  }

  /// Applies [change] to the printers as last saved, and keeps it only once
  /// it is on disk — the list on screen is always the list the till prints
  /// from. Writes run one at a time, each on the result of the one before,
  /// so two quick taps cannot overwrite each other.
  Future<bool> _commit(DevicePrinters Function(DevicePrinters) change) {
    final write = _writes.then((_) => _save(change(_printers)));
    _writes = write.then<void>((_) {}, onError: (_) {});
    return write;
  }

  Future<bool> _save(DevicePrinters next) async {
    final previousReceipt = receiptPrinter;
    _isSaving = true;
    _notify();

    final result = await _repository.saveDevicePrinters(next);
    _isSaving = false;
    final saved = result is Ok<void>;
    _hasSaveError = !saved;
    if (saved) {
      _printers = next;
      _forgetRemovedPrinters();
      final receipt = receiptPrinter;
      if (receipt?.id != previousReceipt?.id ||
          !_sameDevice(receipt?.endpoint, previousReceipt?.endpoint)) {
        _watchReceiptPrinter(checkNow: true);
      }
    }
    _notify();
    return saved;
  }

  static bool _sameDevice(PrinterEndpoint? a, PrinterEndpoint? b) {
    if (a == null || b == null) {
      return a == b;
    }
    return a.kind == b.kind &&
        a.address == b.address &&
        a.port == b.port &&
        a.outputMode == b.outputMode;
  }

  void _forgetRemovedPrinters() {
    bool gone(String id) => _printers.byId(id) == null;
    _connection.removeWhere((id, _) => gone(id));
    _testResults.removeWhere((id, _) => gone(id));
  }

  void _watchReceiptPrinter({required bool checkNow}) {
    _receiptWatch?.cancel();
    _receiptWatch = null;
    if (receiptPrinter == null || _isDisposed) {
      return;
    }
    if (checkNow) {
      unawaited(checkPrinterConnection());
    }
    _receiptWatch = Timer.periodic(
      _statusCheckInterval,
      (_) => unawaited(checkPrinterConnection()),
    );
  }

  void _trackDiscovery({required bool success, required int discoveredCount}) {
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
        'printer_count': _printers.printers.length,
        'source': 'printing_settings',
      },
      metrics: {'discovered_count': discoveredCount},
      flushImmediately: !success,
    );
  }

  void _notify() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _receiptWatch?.cancel();
    super.dispose();
  }
}
