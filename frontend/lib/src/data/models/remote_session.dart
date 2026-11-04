/// One sign-in to the shop from outside it, through دفتر: a phone or a
/// browser that reached the shop with its installation ID. The backend keeps
/// them so their owner — or whoever manages users — can see and end them.
class RemoteSession {
  const RemoteSession({
    required this.id,
    required this.status,
    required this.deviceName,
    required this.platform,
    required this.browser,
    required this.ipAddress,
    required this.createdAt,
    required this.lastSeenAt,
    required this.expiresAt,
    required this.endedAt,
    required this.endedByName,
    required this.isCurrent,
  });

  final int id;
  final RemoteSessionStatus status;

  /// The name the device gave when it paired; often empty for a browser.
  final String deviceName;

  /// What kind of device, read from its user agent: iphone, ipad, android,
  /// windows, mac, chromeos, linux or other.
  final String platform;

  /// safari, chrome, edge, firefox, samsung, opera or other.
  final String browser;
  final String ipAddress;
  final DateTime? createdAt;
  final DateTime? lastSeenAt;
  final DateTime? expiresAt;
  final DateTime? endedAt;
  final String endedByName;

  /// The session this very request is made in.
  final bool isCurrent;

  bool get isActive => status == RemoteSessionStatus.active;

  RemoteSession copyWith({RemoteSessionStatus? status}) {
    return RemoteSession(
      id: id,
      status: status ?? this.status,
      deviceName: deviceName,
      platform: platform,
      browser: browser,
      ipAddress: ipAddress,
      createdAt: createdAt,
      lastSeenAt: lastSeenAt,
      expiresAt: expiresAt,
      endedAt: endedAt,
      endedByName: endedByName,
      isCurrent: isCurrent,
    );
  }

  factory RemoteSession.fromJson(Map<String, Object?> json) {
    return RemoteSession(
      id: (json['id'] as num?)?.toInt() ?? 0,
      status: RemoteSessionStatus.fromWire(json['status']?.toString() ?? ''),
      deviceName: json['device_name']?.toString().trim() ?? '',
      platform: json['platform']?.toString() ?? 'other',
      browser: json['browser']?.toString() ?? 'other',
      ipAddress: json['ip_address']?.toString() ?? '',
      createdAt: _date(json['created_at']),
      lastSeenAt: _date(json['last_seen_at']),
      expiresAt: _date(json['expires_at']),
      endedAt: _date(json['ended_at']),
      endedByName: json['ended_by_name']?.toString() ?? '',
      isCurrent: json['is_current'] == true,
    );
  }

  static List<RemoteSession> listFromJson(Object? decoded) {
    if (decoded is! List) {
      return const [];
    }
    return [
      for (final item in decoded)
        if (item is Map<String, Object?>) RemoteSession.fromJson(item),
    ];
  }
}

enum RemoteSessionStatus {
  active,
  expired,
  revoked,
  signedOut,
  remoteSignInDisabled;

  static RemoteSessionStatus fromWire(String value) {
    return switch (value) {
      'active' => active,
      'expired' => expired,
      'signed_out' => signedOut,
      'remote_sign_in_disabled' => remoteSignInDisabled,
      _ => revoked,
    };
  }
}

DateTime? _date(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
