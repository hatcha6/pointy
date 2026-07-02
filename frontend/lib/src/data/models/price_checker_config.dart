import 'dart:convert';

/// Which device camera the kiosk scans with. Front is the default: a shelf
/// price checker faces the shopper, so the camera looking back at them is the
/// one a product gets held up to.
enum PriceCheckerCameraFacing {
  front,
  back;

  static PriceCheckerCameraFacing fromJson(Object? value) {
    return value == 'back'
        ? PriceCheckerCameraFacing.back
        : PriceCheckerCameraFacing.front;
  }

  String toJson() => name;
}

/// Per-device configuration for "price checker" (kiosk) mode.
///
/// This is a *device* concern, not an account one: a tablet bolted to a shelf
/// runs as a customer-facing price checker while the till next to it runs the
/// full POS. It is persisted locally (SharedPreferences) and never leaves the
/// device except as a best-effort self-registration into the backend fleet.
///
/// [pin] guards leaving kiosk mode. We keep it even while [enabled] is false so
/// that re-entering kiosk mode (from the login screen) doesn't require setting
/// the PIN again — only a brand-new device with no PIN runs first-time setup.
class PriceCheckerConfig {
  const PriceCheckerConfig({
    required this.enabled,
    required this.pin,
    required this.deviceName,
    required this.location,
    required this.identifier,
    this.cameraEnabled = true,
    this.cameraFacing = PriceCheckerCameraFacing.front,
    this.foundDwellSeconds = defaultFoundDwellSeconds,
  });

  /// How long a found product stays on screen before the kiosk goes back to
  /// asking for a scan. Bounded so a mistyped value can't freeze the kiosk.
  static const int defaultFoundDwellSeconds = 8;
  static const int minFoundDwellSeconds = 3;
  static const int maxFoundDwellSeconds = 30;

  /// Whether this device should boot straight into the kiosk screen.
  final bool enabled;

  /// The PIN required to leave kiosk mode. Empty means "never configured".
  final String pin;

  /// Friendly name shown in the backend fleet list (e.g. "Aisle 3").
  final String deviceName;

  /// Optional physical location, shown in the fleet list.
  final String location;

  /// Stable identifier used to self-register and attribute scans to this
  /// device. Generated once, the first time the device is configured.
  final String identifier;

  /// Whether to scan barcodes with the device camera (on platforms that have
  /// one). A wedge/USB scanner keeps working either way.
  final bool cameraEnabled;

  /// Which camera the kiosk scans with.
  final PriceCheckerCameraFacing cameraFacing;

  /// Seconds a found product stays on screen before auto-resetting.
  final int foundDwellSeconds;

  /// A PIN has been set, so the device can re-enter kiosk mode without setup.
  bool get isConfigured => pin.isNotEmpty;

  factory PriceCheckerConfig.empty() {
    return const PriceCheckerConfig(
      enabled: false,
      pin: '',
      deviceName: '',
      location: '',
      identifier: '',
    );
  }

  PriceCheckerConfig copyWith({
    bool? enabled,
    String? pin,
    String? deviceName,
    String? location,
    String? identifier,
    bool? cameraEnabled,
    PriceCheckerCameraFacing? cameraFacing,
    int? foundDwellSeconds,
  }) {
    return PriceCheckerConfig(
      enabled: enabled ?? this.enabled,
      pin: pin ?? this.pin,
      deviceName: deviceName ?? this.deviceName,
      location: location ?? this.location,
      identifier: identifier ?? this.identifier,
      cameraEnabled: cameraEnabled ?? this.cameraEnabled,
      cameraFacing: cameraFacing ?? this.cameraFacing,
      foundDwellSeconds: _clampDwell(
        foundDwellSeconds ?? this.foundDwellSeconds,
      ),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'enabled': enabled,
      'pin': pin,
      'device_name': deviceName,
      'location': location,
      'identifier': identifier,
      'camera_enabled': cameraEnabled,
      'camera_facing': cameraFacing.toJson(),
      'found_dwell_seconds': foundDwellSeconds,
    };
  }

  factory PriceCheckerConfig.fromJson(Map<String, Object?> json) {
    return PriceCheckerConfig(
      enabled: json['enabled'] == true,
      pin: json['pin']?.toString() ?? '',
      deviceName: json['device_name']?.toString() ?? '',
      location: json['location']?.toString() ?? '',
      identifier: json['identifier']?.toString() ?? '',
      // Configs saved before camera support existed omit these keys.
      cameraEnabled: json['camera_enabled'] != false,
      cameraFacing: PriceCheckerCameraFacing.fromJson(json['camera_facing']),
      foundDwellSeconds: _clampDwell(switch (json['found_dwell_seconds']) {
        final int seconds => seconds,
        final String seconds =>
          int.tryParse(seconds) ?? defaultFoundDwellSeconds,
        _ => defaultFoundDwellSeconds,
      }),
    );
  }

  static int _clampDwell(int seconds) {
    return seconds.clamp(minFoundDwellSeconds, maxFoundDwellSeconds);
  }

  String encode() => jsonEncode(toJson());

  static PriceCheckerConfig decode(String? encoded) {
    if (encoded == null || encoded.isEmpty) {
      return PriceCheckerConfig.empty();
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, Object?>) {
      return PriceCheckerConfig.empty();
    }
    return PriceCheckerConfig.fromJson(decoded);
  }
}
