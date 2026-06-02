import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/connection_profile.dart';

abstract class ConnectionProfileStorage {
  Future<ConnectionProfile?> loadProfile();
  Future<void> saveProfile(ConnectionProfile profile);
  Future<String> loadOrCreateDeviceId();
}

class SharedPreferencesConnectionProfileStorage
    implements ConnectionProfileStorage {
  const SharedPreferencesConnectionProfileStorage();

  static const _profileKey = 'pointy.connection.profile.v1';
  static const _deviceIdKey = 'pointy.connection.device_id.v1';

  @override
  Future<ConnectionProfile?> loadProfile() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_profileKey);
    if (encoded == null || encoded.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is Map<String, Object?>) {
        return ConnectionProfile.fromJson(decoded);
      }
      if (decoded is Map) {
        return ConnectionProfile.fromJson(decoded.cast<String, Object?>());
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  @override
  Future<void> saveProfile(ConnectionProfile profile) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_profileKey, jsonEncode(profile.toJson()));
  }

  @override
  Future<String> loadOrCreateDeviceId() async {
    final preferences = await SharedPreferences.getInstance();
    final existing = preferences.getString(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final generated = _generateDeviceId();
    await preferences.setString(_deviceIdKey, generated);
    return generated;
  }
}

class MemoryConnectionProfileStorage implements ConnectionProfileStorage {
  MemoryConnectionProfileStorage({ConnectionProfile? profile, String? deviceId})
    : _profile = profile,
      _deviceId = deviceId;

  ConnectionProfile? _profile;
  String? _deviceId;

  @override
  Future<ConnectionProfile?> loadProfile() async => _profile;

  @override
  Future<void> saveProfile(ConnectionProfile profile) async {
    _profile = profile;
  }

  @override
  Future<String> loadOrCreateDeviceId() async {
    return _deviceId ??= _generateDeviceId();
  }
}

String _generateDeviceId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  final encoded = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return 'device-$encoded';
}
