import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/device_printers.dart';
import '../../../data/models/printer_config.dart';
import '../../../data/services/barcode_label_calibration.dart';
import 'printing_settings_view_model.dart';

enum BarcodeLabelLanguageDetectionOutcome {
  none,
  detected,
  inferred,
  unavailable,
  failed,
}

/// Adds a printer to this device, or changes one, as a draft.
///
/// Nothing reaches the till until [save]: a half-typed address never becomes
/// where the next receipt goes, and closing the editor leaves every printer
/// as it was. Test prints and calibration sheets run on the draft, so a
/// printer can be proven before it is trusted with a job.
class PrinterEditorViewModel extends ChangeNotifier {
  factory PrinterEditorViewModel(
    PrintingSettingsViewModel settings, {
    DevicePrinter? printer,
  }) {
    return PrinterEditorViewModel._(
      settings,
      printer ?? _blankPrinter(settings),
      isNew: printer == null,
    );
  }

  PrinterEditorViewModel._(this._settings, this._initial, {required this.isNew})
    : _draft = _initial {
    if (!isNew) {
      _connection = _settings.connectionOf(_initial.id);
    }
  }

  /// Looks for printers and asks the current one how it is. Separate from
  /// the constructor because both announce themselves to listeners, and the
  /// editor is built inside a frame.
  void start() {
    if (!isNew) {
      unawaited(checkConnection());
    }
    if (_settings.discoveredPrinters.isEmpty) {
      unawaited(_settings.discoverPrinters());
    }
  }

  /// A till's first printer does receipts and labels — what its one printer
  /// always did. Later printers start with no job: which one they take is
  /// exactly the decision the shop is adding them to make.
  static DevicePrinter _blankPrinter(PrintingSettingsViewModel settings) {
    return DevicePrinter(
      id: newDevicePrinterId(),
      config: PrinterConfig.defaultConfig(),
      roles: settings.printers.isEmpty
          ? const {PrinterRole.posReceipt, PrinterRole.barcodeLabels}
          : const {},
    );
  }

  final PrintingSettingsViewModel _settings;
  final bool isNew;
  final DevicePrinter _initial;
  DevicePrinter _draft;

  bool _isSaving = false;
  bool _hasSaveError = false;
  bool _isDisposed = false;
  int _deviceGeneration = 0;
  PrinterConnectionState _connection = PrinterConnectionState.unknown;
  PrinterTestKind? _runningTest;
  bool _isCalibrating = false;
  PrinterTestResult? _lastTest;
  bool _isDetectingLanguage = false;
  BarcodeLabelLanguageDetectionOutcome _detection =
      BarcodeLabelLanguageDetectionOutcome.none;

  PrintingSettingsViewModel get settings => _settings;
  DevicePrinter get draft => _draft;
  PrinterEndpoint get endpoint => _draft.endpoint;

  /// Whether the draft names an actual device yet.
  bool get hasDevice => endpoint.isConfigured;
  bool get isDirty => !_draft.sameAs(_initial);
  bool get isSaving => _isSaving;
  bool get hasSaveError => _hasSaveError;
  bool get canSave => hasDevice && !_isSaving && (isNew || isDirty);

  /// Bumps whenever the draft is pointed at another device, so fields seeded
  /// from the old device's settings reseed from the new one.
  int get deviceGeneration => _deviceGeneration;

  PrinterConnectionState get connection => _connection;
  PrinterTestKind? get runningTest => _runningTest;
  bool get isCalibrating => _isCalibrating;
  PrinterTestResult? get lastTest => _lastTest;
  bool get isDetectingLanguage => _isDetectingLanguage;
  BarcodeLabelLanguageDetectionOutcome get detection => _detection;

  /// A test, a calibration sheet or a probe is on its way to the printer.
  bool get isBusy =>
      _runningTest != null || _isCalibrating || _isDetectingLanguage;

  /// Settings shown for the jobs the draft does: receipt settings serve the
  /// kitchen chit too, which prints on the same roll.
  bool get showsReceiptSettings =>
      _draft.holds(PrinterRole.posReceipt) ||
      _draft.kitchenStationIds.isNotEmpty;
  bool get showsLabelSettings => _draft.holds(PrinterRole.barcodeLabels);

  /// The printer that does [role] now, when it is not this one — the one the
  /// job moves from if this printer takes it.
  DevicePrinter? otherHolderOf(PrinterRole role) {
    final holder = _settings.holderOf(role);
    return holder?.id == _draft.id ? null : holder;
  }

  DevicePrinter? otherKitchenPrinterFor(int stationId) {
    final holder = _settings.kitchenPrinterFor(stationId);
    return holder?.id == _draft.id ? null : holder;
  }

  /// Another printer on this device already talking to the draft's device.
  DevicePrinter? get duplicateOf {
    if (!hasDevice) {
      return null;
    }
    return _settings.printers.printers
        .where(
          (printer) =>
              printer.id != _draft.id &&
              _sameDevice(printer.endpoint, endpoint),
        )
        .firstOrNull;
  }

  /// Whether the draft may take [role]. Before a device is chosen every job
  /// is open: the one the device cannot do is dropped when it is chosen.
  bool canTake(PrinterRole role) => !hasDevice || endpoint.canServe(role);

  bool get canTakeKitchen => !hasDevice || endpoint.canServeKitchen;

  /// The tests worth offering: one per job, or the plain one for a printer
  /// with no job yet.
  List<PrinterTestKind> get availableTests {
    final kinds = printerTestKinds(_draft);
    return kinds.isEmpty ? [primaryTestKind(_draft)] : kinds;
  }

  void setLabel(String value) {
    _update(_draft.copyWith(label: value));
  }

  void setRole(PrinterRole role, bool selected) {
    if (selected && !canTake(role)) {
      return;
    }
    _update(
      _draft.copyWith(
        roles: selected
            ? {..._draft.roles, role}
            : ({..._draft.roles}..remove(role)),
      ),
    );
  }

  void setKitchenStation(int stationId, bool selected) {
    if (selected && !canTakeKitchen) {
      return;
    }
    _update(
      _draft.copyWith(
        kitchenStationIds: selected
            ? {..._draft.kitchenStationIds, stationId}
            : ({..._draft.kitchenStationIds}..remove(stationId)),
      ),
    );
  }

  /// Points the draft at [device]. A new printer takes the device as found;
  /// a printer that already has settings keeps them — paper, label geometry,
  /// calibration — and only changes which device it talks to, because the
  /// usual reason is the same printer on a new port or a new address.
  void selectDevice(PrinterEndpoint device) {
    final current = endpoint;
    final next = current.isConfigured
        ? current.copyWith(
            kind: device.kind,
            name: device.name,
            address: device.address,
            port: device.port,
            baudRate: device.baudRate,
            outputMode: device.outputMode,
          )
        : device;
    _updateDevice(next);
  }

  /// A network printer that does not announce itself, typed in by address.
  void useNetworkAddress(String host, {int port = 9100}) {
    _updateDevice(
      endpoint.copyWith(
        kind: PrintTransportKind.wifi,
        name: '',
        address: host.trim(),
        port: port,
        outputMode: PrinterOutputMode.escPos,
      ),
    );
  }

  void updatePaperWidth(String value) => _updateEndpoint(
    endpoint.copyWith(
      paperWidthMm: int.tryParse(value) ?? endpoint.paperWidthMm,
    ),
  );

  void updatePdfPageSize(PdfPageSize size) =>
      _updateEndpoint(endpoint.copyWith(pdfPageSize: size));

  void updateCodeTable(String value) =>
      _updateEndpoint(endpoint.copyWith(codeTable: value.trim()));

  void updateCapabilityProfile(String value) {
    final trimmed = value.trim();
    _updateEndpoint(
      endpoint.copyWith(
        capabilityProfile: trimmed.isEmpty ? 'default' : trimmed,
      ),
    );
  }

  void updateCutMode(ReceiptCutMode mode) =>
      _updateEndpoint(endpoint.copyWith(cutMode: mode));

  void updateFeedLines(String value) => _updateEndpoint(
    endpoint.copyWith(feedLines: int.tryParse(value) ?? endpoint.feedLines),
  );

  void updateCompactReceipt(bool value) =>
      _updateEndpoint(endpoint.copyWith(compactReceipt: value));

  void updateBarcodeLabelLanguage(BarcodeLabelPrinterLanguage language) =>
      _updateEndpoint(endpoint.copyWith(barcodeLabelLanguage: language));

  void updateLabelWidth(String value) => _updateEndpoint(
    endpoint.copyWith(
      labelWidthMm: int.tryParse(value) ?? endpoint.labelWidthMm,
    ),
  );

  void updateLabelHeight(String value) => _updateEndpoint(
    endpoint.copyWith(
      labelHeightMm: int.tryParse(value) ?? endpoint.labelHeightMm,
    ),
  );

  void updateLabelGap(String value) => _updateEndpoint(
    endpoint.copyWith(labelGapMm: int.tryParse(value) ?? endpoint.labelGapMm),
  );

  void updateLabelDpi(String value) => _updateEndpoint(
    endpoint.copyWith(labelDpi: int.tryParse(value) ?? endpoint.labelDpi),
  );

  void updateLabelPdfSize(BarcodeLabelPdfSize size) =>
      _updateEndpoint(endpoint.copyWith(labelPdfSize: size));

  void updateLabelPdfOffsetX(String value) => _updateEndpoint(
    endpoint.copyWith(
      labelPdfOffsetXMm: int.tryParse(value) ?? endpoint.labelPdfOffsetXMm,
    ),
  );

  void updateLabelPdfOffsetY(String value) => _updateEndpoint(
    endpoint.copyWith(
      labelPdfOffsetYMm: int.tryParse(value) ?? endpoint.labelPdfOffsetYMm,
    ),
  );

  void updateLabelPdfPitch(String value) => _updateEndpoint(
    endpoint.copyWith(
      labelPdfPitchMm: double.tryParse(value) ?? endpoint.labelPdfPitchMm,
    ),
  );

  void updateLabelRotation(int quarterTurns) => _updateEndpoint(
    endpoint.copyWith(labelRotationQuarterTurns: ((quarterTurns % 4) + 4) % 4),
  );

  Future<void> discoverPrinters() => _settings.discoverPrinters();

  Future<void> checkConnection() async {
    if (!hasDevice || _connection == PrinterConnectionState.checking) {
      return;
    }
    final asked = endpoint;
    _connection = PrinterConnectionState.checking;
    _notify();

    var available = false;
    try {
      available = (await _settings.repository.printerStatus(
        _draft.config,
      )).isAvailable;
    } on Object {
      available = false;
    }
    if (_isDisposed) {
      return;
    }
    // Switched to another device while this one was being asked.
    if (!identical(asked, endpoint) && !_sameDevice(asked, endpoint)) {
      _connection = PrinterConnectionState.unknown;
      _notify();
      return;
    }
    _connection = available
        ? PrinterConnectionState.connected
        : PrinterConnectionState.disconnected;
    _notify();
  }

  Future<void> runTest(PrinterTestKind kind) async {
    if (isBusy || !hasDevice) {
      return;
    }
    _runningTest = kind;
    _lastTest = null;
    _notify();

    final result = await runPrinterTest(
      _settings.repository,
      _draft.config,
      kind,
    );
    if (_isDisposed) {
      return;
    }
    _runningTest = null;
    _lastTest = PrinterTestResult(kind, result.isSuccess);
    _connection = result.isSuccess
        ? PrinterConnectionState.connected
        : PrinterConnectionState.disconnected;
    trackPrinterTest(
      _settings.analyticsEngine,
      kind: kind,
      endpoint: endpoint,
      result: result,
      source: 'printer_editor',
    );
    _notify();
  }

  /// Prints a calibration sheet, so the die-cut numbers are read off the
  /// sticker rather than guessed at.
  Future<void> printCalibration(BarcodeLabelCalibrationSheet sheet) async {
    if (isBusy || !hasDevice) {
      return;
    }
    _isCalibrating = true;
    _lastTest = null;
    _notify();

    final result = await _settings.repository.printBarcodeLabelCalibration(
      _draft.config,
      sheet,
    );
    if (_isDisposed) {
      return;
    }
    _isCalibrating = false;
    _lastTest = PrinterTestResult(
      PrinterTestKind.barcodeLabel,
      result.isSuccess,
    );
    trackAuditEvent(
      _settings.analyticsEngine,
      name: 'printing.printer.label_calibrated',
      severity: result.isSuccess
          ? AnalyticsEventSeverity.info
          : AnalyticsEventSeverity.warning,
      entityType: 'printer_settings',
      attributes: {
        'sheet': sheet.name,
        'transport_kind': endpoint.kind.name,
        'outcome': result.isSuccess ? 'success' : 'failed',
      },
    );
    _notify();
  }

  Future<void> detectLabelLanguage() async {
    if (isBusy || !hasDevice) {
      return;
    }
    _isDetectingLanguage = true;
    _detection = BarcodeLabelLanguageDetectionOutcome.none;
    _notify();

    final result = await _settings.repository.detectBarcodeLabelLanguage(
      _draft.config,
    );
    if (_isDisposed) {
      return;
    }
    switch (result) {
      case Ok(:final value) when value.isSuccess && value.language != null:
        _draft = _draft.copyWith(
          config: _draft.config.copyWith(
            endpoint: endpoint.copyWith(barcodeLabelLanguage: value.language),
          ),
        );
        _detection = value.isInferred
            ? BarcodeLabelLanguageDetectionOutcome.inferred
            : BarcodeLabelLanguageDetectionOutcome.detected;
      case Ok():
        _detection = BarcodeLabelLanguageDetectionOutcome.unavailable;
      case Error():
        _detection = BarcodeLabelLanguageDetectionOutcome.failed;
    }
    trackAuditEvent(
      _settings.analyticsEngine,
      name:
          _detection == BarcodeLabelLanguageDetectionOutcome.detected ||
              _detection == BarcodeLabelLanguageDetectionOutcome.inferred
          ? 'printing.barcode_label_language.detected'
          : 'printing.barcode_label_language.detect_failed',
      entityType: 'printer_settings',
      attributes: {
        'transport_kind': endpoint.kind.name,
        'barcode_label_language': endpoint.barcodeLabelLanguage.name,
        'outcome': _detection.name,
      },
    );
    _isDetectingLanguage = false;
    _notify();
  }

  /// Saves the draft into the device's printer list. False, with
  /// [hasSaveError] set, when it could not be written — the editor stays
  /// open with everything still in it.
  Future<bool> save() async {
    if (!canSave) {
      return false;
    }
    _isSaving = true;
    _hasSaveError = false;
    _notify();

    final saved = await _settings.savePrinter(
      _draft.copyWith(label: _draft.label.trim()),
    );
    if (_isDisposed) {
      return saved;
    }
    _isSaving = false;
    _hasSaveError = !saved;
    _notify();
    return saved;
  }

  void _updateDevice(PrinterEndpoint next) {
    _draft = _draft
        .copyWith(config: _draft.config.copyWith(endpoint: next))
        .withCompatibleJobs();
    _deviceGeneration += 1;
    _connection = PrinterConnectionState.unknown;
    _lastTest = null;
    _detection = BarcodeLabelLanguageDetectionOutcome.none;
    _notify();
    unawaited(checkConnection());
  }

  void _updateEndpoint(PrinterEndpoint next) {
    _update(_draft.copyWith(config: _draft.config.copyWith(endpoint: next)));
  }

  void _update(DevicePrinter next) {
    _draft = next;
    _lastTest = null;
    _notify();
  }

  static bool _sameDevice(PrinterEndpoint a, PrinterEndpoint b) {
    return a.kind == b.kind &&
        a.address == b.address &&
        a.port == b.port &&
        a.outputMode == b.outputMode;
  }

  void _notify() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
