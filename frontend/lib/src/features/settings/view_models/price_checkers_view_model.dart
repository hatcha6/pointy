import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/price_check_event.dart';
import '../../../data/models/price_checker_device.dart';
import '../../../data/repositories/price_checker_repository.dart';

/// Drives the price-checker monitoring page: loads the fleet, runs LAN scans,
/// and exposes the fleet roll-up counts the header surfaces. Mutations re-load
/// the device list so the UI always reflects the backend.
class PriceCheckersViewModel extends ChangeNotifier {
  PriceCheckersViewModel(this._repository);

  final PriceCheckerRepository _repository;

  List<PriceCheckerDevice> _devices = const [];
  bool _isLoading = false;
  bool _isScanning = false;
  bool _hasLoadError = false;
  PriceCheckerScanSummary? _lastScanSummary;

  List<PriceCheckerDevice> get devices => _devices;
  bool get isLoading => _isLoading;
  bool get isScanning => _isScanning;
  bool get isBusy => _isLoading || _isScanning;
  bool get hasLoadError => _hasLoadError;
  PriceCheckerScanSummary? get lastScanSummary => _lastScanSummary;

  bool get hasDevices => _devices.isNotEmpty;
  int get totalCount => _devices.length;
  int get activeCount => _devices.where((device) => device.isActive).length;
  int get discoveredCount =>
      _devices.where((device) => device.isDiscovered).length;
  int get disabledCount => _devices.where((device) => device.isDisabled).length;

  /// Devices the backend reports as actively serving lookups right now.
  int get servingCount => _devices.where((device) => device.isServing).length;

  Future<void> loadDevices() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadDevices();
    switch (result) {
      case Ok<List<PriceCheckerDevice>>():
        _devices = result.value;
      case Error<List<PriceCheckerDevice>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Runs a network scan, then refreshes the list. Returns the scan summary, or
  /// null if the scan call itself failed.
  Future<PriceCheckerScanSummary?> runScan() async {
    if (_isScanning) {
      return null;
    }
    _isScanning = true;
    notifyListeners();

    final result = await _repository.runScan();
    _isScanning = false;

    switch (result) {
      case Ok<PriceCheckerScanSummary>():
        _lastScanSummary = result.value;
        notifyListeners();
        await loadDevices();
        return result.value;
      case Error<PriceCheckerScanSummary>():
        notifyListeners();
        return null;
    }
  }

  /// Loads a single device's recent scan events for the detail screen. Returns
  /// null on failure so the caller can show an inline error.
  Future<List<PriceCheckEvent>?> loadEventsForDevice(int deviceId) async {
    final result = await _repository.loadEvents(deviceId: deviceId);
    return switch (result) {
      Ok<List<PriceCheckEvent>>(value: final events) => events,
      Error<List<PriceCheckEvent>>() => null,
    };
  }
}
