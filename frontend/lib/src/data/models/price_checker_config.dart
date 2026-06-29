import 'dart:convert';

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
  });

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
  }) {
    return PriceCheckerConfig(
      enabled: enabled ?? this.enabled,
      pin: pin ?? this.pin,
      deviceName: deviceName ?? this.deviceName,
      location: location ?? this.location,
      identifier: identifier ?? this.identifier,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'enabled': enabled,
      'pin': pin,
      'device_name': deviceName,
      'location': location,
      'identifier': identifier,
    };
  }

  factory PriceCheckerConfig.fromJson(Map<String, Object?> json) {
    return PriceCheckerConfig(
      enabled: json['enabled'] == true,
      pin: json['pin']?.toString() ?? '',
      deviceName: json['device_name']?.toString() ?? '',
      location: json['location']?.toString() ?? '',
      identifier: json['identifier']?.toString() ?? '',
    );
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
