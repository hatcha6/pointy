import 'dart:math';

import 'package:flutter/widgets.dart';

import '../../data/models/price_checker_config.dart';
import '../../data/services/device_settings_storage_service.dart';

/// Holds this device's [PriceCheckerConfig] and persists changes.
///
/// Pure local state (persist + notify only) — deliberately free of network or
/// native side effects so it can drive top-level routing safely. The setup flow
/// performs best-effort self-registration and auto-start toggling around it.
///
/// Mirrors [ThemeController]: loaded once at startup, written back on change,
/// exposed to the tree via [PriceCheckerModeScope] so the app can route to the
/// kiosk the moment the mode flips.
class PriceCheckerModeController extends ChangeNotifier {
  PriceCheckerModeController({
    DeviceSettingsStorageService storage = const DeviceSettingsStorageService(),
  }) : _storage = storage;

  final DeviceSettingsStorageService _storage;

  PriceCheckerConfig _config = PriceCheckerConfig.empty();
  PriceCheckerConfig get config => _config;

  /// Whether this device should be showing the kiosk right now.
  bool get enabled => _config.enabled;

  /// A PIN has been set, so the device can re-enter kiosk mode without setup.
  bool get isConfigured => _config.isConfigured;

  /// Loads the persisted config, if any. Safe to call once at startup.
  Future<void> load() async {
    _config = await _storage.loadPriceCheckerConfig();
    notifyListeners();
  }

  /// First-time setup (or re-setup): record the PIN/name/location, mint a stable
  /// identifier if there isn't one, and switch the device into kiosk mode.
  Future<void> configureAndEnable({
    required String pin,
    String deviceName = '',
    String location = '',
  }) async {
    final identifier = _config.identifier.isNotEmpty
        ? _config.identifier
        : _mintIdentifier(deviceName);
    await _update(
      _config.copyWith(
        enabled: true,
        pin: pin,
        deviceName: deviceName,
        location: location,
        identifier: identifier,
      ),
    );
  }

  /// Re-enter kiosk mode on an already-configured device (login-screen button).
  Future<void> enter() async {
    if (!_config.isConfigured) {
      return;
    }
    await _update(_config.copyWith(enabled: true));
  }

  /// Leave kiosk mode (correct PIN entered). The config is kept so the device
  /// can be sent back into kiosk mode without re-running setup.
  Future<void> exit() async {
    if (!_config.enabled) {
      return;
    }
    await _update(_config.copyWith(enabled: false));
  }

  /// Toggle from Device Settings without leaving via the PIN.
  Future<void> setEnabled(bool value) async {
    if (value == _config.enabled) {
      return;
    }
    await _update(_config.copyWith(enabled: value));
  }

  Future<void> updatePin(String pin) async {
    await _update(_config.copyWith(pin: pin));
  }

  Future<void> updateDetails({String? deviceName, String? location}) async {
    await _update(_config.copyWith(deviceName: deviceName, location: location));
  }

  /// Camera + dwell preferences, edited from Device Settings.
  Future<void> updateScanSettings({
    bool? cameraEnabled,
    PriceCheckerCameraFacing? cameraFacing,
    bool? torchEnabled,
    bool? speakResults,
    int? foundDwellSeconds,
  }) async {
    await _update(
      _config.copyWith(
        cameraEnabled: cameraEnabled,
        cameraFacing: cameraFacing,
        torchEnabled: torchEnabled,
        speakResults: speakResults,
        foundDwellSeconds: foundDwellSeconds,
      ),
    );
  }

  /// Forget everything — turns the device back into a plain POS device.
  Future<void> clear() async {
    await _update(PriceCheckerConfig.empty());
  }

  bool verifyPin(String input) {
    return _config.isConfigured && input == _config.pin;
  }

  Future<void> _update(PriceCheckerConfig next) async {
    _config = next;
    notifyListeners();
    await _storage.savePriceCheckerConfig(next);
  }

  static String _mintIdentifier(String name) {
    final slug = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'(^-+|-+$)'), '');
    final random = Random();
    final suffix = List.generate(
      6,
      (_) => '0123456789abcdef'[random.nextInt(16)],
    ).join();
    return 'pc-${slug.isEmpty ? 'kiosk' : slug}-$suffix';
  }
}

/// Makes the [PriceCheckerModeController] available to descendants and rebuilds
/// them (and top-level routing) when the mode changes.
class PriceCheckerModeScope
    extends InheritedNotifier<PriceCheckerModeController> {
  const PriceCheckerModeScope({
    super.key,
    required PriceCheckerModeController controller,
    required super.child,
  }) : super(notifier: controller);

  static PriceCheckerModeController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<PriceCheckerModeScope>();
    assert(scope?.notifier != null, 'No PriceCheckerModeScope in the tree');
    return scope!.notifier!;
  }

  static PriceCheckerModeController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<PriceCheckerModeScope>()
        ?.notifier;
  }
}
