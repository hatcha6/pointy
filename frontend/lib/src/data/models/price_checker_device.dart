/// Transport family a price-checker device speaks. Mirrors the backend
/// `PriceCheckerDevice.Transport` choices; [unknown] guards against a future
/// backend value the app hasn't shipped support for yet.
enum PriceCheckerTransport { http, tcp, udp, unknown }

/// Lifecycle of a device as the backend tracks it.
enum PriceCheckerStatus { discovered, active, disabled, unknown }

/// How a device first joined the fleet.
enum PriceCheckerDiscoveryMethod { manual, scan, self, unknown }

/// Arabic rendering tier the device's display supports.
enum PriceCheckerArabicSupport { none, unicode, cp1256, glyphs, unknown }

/// A self-service in-store barcode price verifier, as returned by
/// `GET /api/price-checker-devices/`.
///
/// Read-only on the client: this powers the settings monitoring page, so the
/// model deliberately mirrors the serializer's fields rather than offering
/// mutation drafts.
class PriceCheckerDevice {
  const PriceCheckerDevice({
    required this.id,
    required this.identifier,
    required this.name,
    required this.driver,
    required this.make,
    required this.model,
    required this.transport,
    required this.transportRaw,
    required this.status,
    required this.statusRaw,
    required this.discoveryMethod,
    required this.discoveryMethodRaw,
    required this.arabicSupport,
    required this.arabicSupportRaw,
    required this.encoding,
    required this.displayRows,
    required this.displayCols,
    required this.location,
    required this.isServing,
    this.address,
    this.port,
    this.macAddress = '',
    this.lastSeenAt,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final String identifier;
  final String name;
  final String driver;
  final String make;
  final String model;
  final PriceCheckerTransport transport;

  /// The raw backend value, kept so the UI can fall back to it if the enum
  /// resolved to [PriceCheckerTransport.unknown].
  final String transportRaw;
  final PriceCheckerStatus status;
  final String statusRaw;
  final PriceCheckerDiscoveryMethod discoveryMethod;
  final String discoveryMethodRaw;
  final PriceCheckerArabicSupport arabicSupport;
  final String arabicSupportRaw;
  final String encoding;
  final int displayRows;
  final int displayCols;
  final String location;
  final bool isServing;
  final String? address;
  final int? port;
  final String macAddress;
  final DateTime? lastSeenAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isActive => status == PriceCheckerStatus.active;
  bool get isDisabled => status == PriceCheckerStatus.disabled;
  bool get isDiscovered => status == PriceCheckerStatus.discovered;

  /// A human-friendly label for the device, falling back to its identifier.
  String get displayName => name.trim().isNotEmpty ? name.trim() : identifier;

  /// "192.168.1.20:9100" when both are known, just the address otherwise.
  String get endpointLabel {
    final host = address?.trim() ?? '';
    if (host.isEmpty) {
      return '';
    }
    return port == null ? host : '$host:$port';
  }

  factory PriceCheckerDevice.fromJson(Map<String, Object?> json) {
    final transportRaw = json['transport']?.toString() ?? '';
    final statusRaw = json['status']?.toString() ?? '';
    final discoveryRaw = json['discovery_method']?.toString() ?? '';
    final arabicRaw = json['arabic_support']?.toString() ?? '';
    final address = json['address']?.toString();
    return PriceCheckerDevice(
      id: _intFromJson(json['id']),
      identifier: json['identifier']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      driver: json['driver']?.toString() ?? '',
      make: json['make']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      transport: _transportFromJson(transportRaw),
      transportRaw: transportRaw,
      status: _statusFromJson(statusRaw),
      statusRaw: statusRaw,
      discoveryMethod: _discoveryFromJson(discoveryRaw),
      discoveryMethodRaw: discoveryRaw,
      arabicSupport: _arabicFromJson(arabicRaw),
      arabicSupportRaw: arabicRaw,
      encoding: json['encoding']?.toString() ?? '',
      displayRows: _intFromJson(json['display_rows']),
      displayCols: _intFromJson(json['display_cols']),
      location: json['location']?.toString() ?? '',
      isServing: json['is_serving'] == true,
      address: address == null || address.isEmpty ? null : address,
      port: _nullableIntFromJson(json['port']),
      macAddress: json['mac_address']?.toString() ?? '',
      lastSeenAt: _dateTimeFromJson(json['last_seen_at']),
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

/// Summary returned by `POST /api/price-checker-devices/scan/`.
class PriceCheckerScanSummary {
  const PriceCheckerScanSummary({
    required this.found,
    required this.registeredCount,
  });

  /// How many candidate devices answered on the network.
  final int found;

  /// How many of those were newly registered or refreshed.
  final int registeredCount;

  factory PriceCheckerScanSummary.fromJson(Map<String, Object?> json) {
    final registered = json['registered'];
    return PriceCheckerScanSummary(
      found: _intFromJson(json['found']),
      registeredCount: registered is List ? registered.length : 0,
    );
  }
}

List<PriceCheckerDevice> priceCheckerDevicesFromResponse(Object? decoded) {
  final items = decoded is Map<String, Object?> && decoded['results'] is List
      ? decoded['results'] as List<Object?>
      : decoded is List<Object?>
      ? decoded
      : const <Object?>[];

  return items
      .whereType<Map<String, Object?>>()
      .map(PriceCheckerDevice.fromJson)
      .toList(growable: false);
}

PriceCheckerTransport _transportFromJson(String value) {
  return switch (value) {
    'http' => PriceCheckerTransport.http,
    'tcp' => PriceCheckerTransport.tcp,
    'udp' => PriceCheckerTransport.udp,
    _ => PriceCheckerTransport.unknown,
  };
}

PriceCheckerStatus _statusFromJson(String value) {
  return switch (value) {
    'discovered' => PriceCheckerStatus.discovered,
    'active' => PriceCheckerStatus.active,
    'disabled' => PriceCheckerStatus.disabled,
    _ => PriceCheckerStatus.unknown,
  };
}

PriceCheckerDiscoveryMethod _discoveryFromJson(String value) {
  return switch (value) {
    'manual' => PriceCheckerDiscoveryMethod.manual,
    'scan' => PriceCheckerDiscoveryMethod.scan,
    'self' => PriceCheckerDiscoveryMethod.self,
    _ => PriceCheckerDiscoveryMethod.unknown,
  };
}

PriceCheckerArabicSupport _arabicFromJson(String value) {
  return switch (value) {
    'none' => PriceCheckerArabicSupport.none,
    'unicode' => PriceCheckerArabicSupport.unicode,
    'cp1256' => PriceCheckerArabicSupport.cp1256,
    'glyphs' => PriceCheckerArabicSupport.glyphs,
    _ => PriceCheckerArabicSupport.unknown,
  };
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse((value ?? '').toString()) ?? 0;
}

int? _nullableIntFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  return int.tryParse(value.toString());
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
