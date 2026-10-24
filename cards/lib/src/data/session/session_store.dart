import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A signed-in device: the relay's token pair and who it is for.
class CustomerSession {
  const CustomerSession({
    required this.sessionId,
    required this.customerId,
    required this.phone,
    required this.accessToken,
    required this.refreshToken,
  });

  /// From the verify answer.
  factory CustomerSession.fromSignIn(Map<String, dynamic> json) {
    final customer = json['customer'] as Map<String, dynamic>? ?? const {};
    return CustomerSession(
      sessionId: json['session_id'] as String? ?? '',
      customerId: customer['id'] as String? ?? '',
      phone: customer['phone'] as String? ?? '',
      accessToken: json['access_token'] as String? ?? '',
      refreshToken: json['refresh_token'] as String? ?? '',
    );
  }

  factory CustomerSession.fromJson(Map<String, dynamic> json) =>
      CustomerSession(
        sessionId: json['session_id'] as String? ?? '',
        customerId: json['customer_id'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        accessToken: json['access_token'] as String? ?? '',
        refreshToken: json['refresh_token'] as String? ?? '',
      );

  final String sessionId;
  final String customerId;
  final String phone;
  final String accessToken;
  final String refreshToken;

  /// The same device with the pair a refresh answered.
  CustomerSession rotated(Map<String, dynamic> json) => CustomerSession(
    sessionId: sessionId,
    customerId: customerId,
    phone: phone,
    accessToken: json['access_token'] as String? ?? accessToken,
    refreshToken: json['refresh_token'] as String? ?? refreshToken,
  );

  Map<String, dynamic> toJson() => {
    'session_id': sessionId,
    'customer_id': customerId,
    'phone': phone,
    'access_token': accessToken,
    'refresh_token': refreshToken,
  };
}

/// Where the session lives between launches.
abstract class SessionStore {
  Future<CustomerSession?> read();
  Future<void> write(CustomerSession session);
  Future<void> clear();
}

/// The device's keychain / keystore: a refresh token is as good as the
/// customer's codes, so it never goes into plain preferences.
class SecureSessionStore implements SessionStore {
  SecureSessionStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'cards.session.v1';
  final FlutterSecureStorage _storage;
  CustomerSession? _cached;
  bool _loaded = false;

  @override
  Future<CustomerSession?> read() async {
    if (_loaded) {
      return _cached;
    }
    try {
      final raw = await _storage.read(key: _key);
      _cached = raw == null
          ? null
          : CustomerSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Exception {
      // A keystore that cannot be read (a restored backup on another
      // device) is a signed-out device, not a crash.
      _cached = null;
    }
    _loaded = true;
    return _cached;
  }

  @override
  Future<void> write(CustomerSession session) async {
    _cached = session;
    _loaded = true;
    await _storage.write(key: _key, value: jsonEncode(session.toJson()));
  }

  @override
  Future<void> clear() async {
    _cached = null;
    _loaded = true;
    await _storage.delete(key: _key);
  }
}

/// In memory only: tests and the preview harness.
class MemorySessionStore implements SessionStore {
  MemorySessionStore([this._session]);

  CustomerSession? _session;

  /// The session as it stands, without waiting.
  CustomerSession? get current => _session;

  @override
  Future<CustomerSession?> read() async => _session;

  @override
  Future<void> write(CustomerSession session) async => _session = session;

  @override
  Future<void> clear() async => _session = null;
}
