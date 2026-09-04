/// Models for the companion camera: a phone paired to this till over the shop
/// LAN, sending it the 2-D codes and photos a laser scanner cannot read.
library;

int _int(Object? value) => switch (value) {
  final int number => number,
  final num number => number.toInt(),
  final String text => int.tryParse(text) ?? 0,
  _ => 0,
};

int? _nullableInt(Object? value) => value == null ? null : _int(value);

String _string(Object? value) => value?.toString() ?? '';

DateTime? _dateTime(Object? value) {
  final raw = value?.toString();
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}

/// A pairing invitation: the QR a till draws for a phone to scan.
class CompanionPairing {
  const CompanionPairing({
    required this.code,
    required this.url,
    required this.tillKey,
    required this.expiresAt,
  });

  factory CompanionPairing.fromJson(Map<String, Object?> json) {
    return CompanionPairing(
      code: _string(json['code']),
      url: _string(json['url']),
      tillKey: _string(json['till_key']),
      expiresAt: _dateTime(json['expires_at']) ?? DateTime.now(),
    );
  }

  final String code;

  /// The address the QR encodes. The code rides in the URL fragment, so this
  /// string is a live credential until it is claimed or expires — never log it.
  final String url;
  final String tillKey;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// A phone currently lending its camera to this till.
class CompanionDevice {
  const CompanionDevice({
    required this.id,
    required this.label,
    required this.isPaused,
    required this.isLive,
    this.pairedByUsername = '',
    this.address = '',
    this.lastSeenAt,
  });

  factory CompanionDevice.fromJson(Map<String, Object?> json) {
    return CompanionDevice(
      id: _int(json['id']),
      label: _string(json['label']),
      isPaused: json['is_paused'] == true,
      isLive: json['is_live'] == true,
      pairedByUsername: _string(json['paired_by_username']),
      address: _string(json['address']),
      lastSeenAt: _dateTime(json['last_seen_at']),
    );
  }

  final int id;
  final String label;
  final bool isPaused;
  final bool isLive;
  final String pairedByUsername;
  final String address;
  final DateTime? lastSeenAt;
}

/// What a companion event carries. [unknown] guards against a backend that has
/// learned a new kind before this build shipped.
enum CompanionEventKind {
  scan,
  capture,
  deviceState,
  unknown;

  static CompanionEventKind parse(String raw) => switch (raw) {
    'scan' => CompanionEventKind.scan,
    'capture' => CompanionEventKind.capture,
    'device_state' => CompanionEventKind.deviceState,
    _ => CompanionEventKind.unknown,
  };
}

/// One thing a phone sent to this till.
class CompanionEvent {
  const CompanionEvent({
    required this.id,
    required this.kind,
    required this.payload,
    this.deviceLabel = '',
    this.attachmentId,
    this.captureRequestId,
    this.createdAt,
  });

  factory CompanionEvent.fromJson(Map<String, Object?> json) {
    final payload = json['payload'];
    return CompanionEvent(
      id: _int(json['id']),
      kind: CompanionEventKind.parse(_string(json['kind'])),
      payload: payload is Map<String, Object?>
          ? payload
          : const <String, Object?>{},
      deviceLabel: _string(json['device_label']),
      attachmentId: _nullableInt(json['attachment']),
      captureRequestId: _nullableInt(json['capture_request']),
      createdAt: _dateTime(json['created_at']),
    );
  }

  final int id;
  final CompanionEventKind kind;
  final Map<String, Object?> payload;
  final String deviceLabel;
  final int? attachmentId;
  final int? captureRequestId;
  final DateTime? createdAt;

  /// The scanned code, for [CompanionEventKind.scan].
  String get scannedValue => _string(payload['value']);

  /// The phone's new state, for [CompanionEventKind.deviceState]: `connected`,
  /// `paused`, `resumed` or `left`.
  String get deviceState => _string(payload['state']);

  /// The attachment's owner, for [CompanionEventKind.capture] — set when the
  /// till asked for a photo of something specific and it filed itself there.
  String get ownerType => _string(payload['owner_type']);
  int? get ownerId => _nullableInt(payload['owner_id']);
}

/// A page of the till's inbox, plus the cursor to resume from.
class CompanionEventPage {
  const CompanionEventPage({required this.cursor, required this.events});

  factory CompanionEventPage.fromJson(Map<String, Object?> json) {
    final raw = json['events'];
    return CompanionEventPage(
      cursor: _int(json['cursor']),
      events: raw is List
          ? raw
                .whereType<Map<String, Object?>>()
                .map(CompanionEvent.fromJson)
                .toList()
          : const <CompanionEvent>[],
    );
  }

  final int cursor;
  final List<CompanionEvent> events;
}

/// A till asking its phone for one specific photo.
class CompanionCaptureRequest {
  const CompanionCaptureRequest({
    required this.id,
    required this.prompt,
    required this.status,
  });

  factory CompanionCaptureRequest.fromJson(Map<String, Object?> json) {
    return CompanionCaptureRequest(
      id: _int(json['id']),
      prompt: _string(json['prompt']),
      status: _string(json['status']),
    );
  }

  final int id;
  final String prompt;
  final String status;
}

List<CompanionDevice> companionDevicesFromResponse(Object? decoded) {
  final items = decoded is Map<String, Object?> && decoded['results'] is List
      ? decoded['results'] as List<Object?>
      : decoded is List<Object?>
      ? decoded
      : const <Object?>[];
  return items
      .whereType<Map<String, Object?>>()
      .map(CompanionDevice.fromJson)
      .toList();
}
