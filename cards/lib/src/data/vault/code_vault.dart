import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../models/order.dart';
import '../settings/app_settings.dart';

/// The codes of delivered orders, kept in the keychain so «كروتي» shows them
/// offline, and which ones the customer marked used. The relay can always read
/// a code back from the supplier, so losing the vault loses nothing.
abstract class CodeVault {
  Future<List<CardCode>?> codes(String orderId);
  Future<void> keep(String orderId, List<CardCode> codes);
  Future<Set<String>> usedCodes();
  Future<void> setUsed(String code, bool used);
  Future<void> clear();
}

class SecureCodeVault implements CodeVault {
  SecureCodeVault([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _usedKey = 'cards.used.v1';

  String _key(String orderId) => 'cards.codes.v1.$orderId';

  @override
  Future<List<CardCode>?> codes(String orderId) async {
    try {
      final raw = await _storage.read(key: _key(orderId));
      if (raw == null) {
        return null;
      }
      return [
        for (final row in jsonDecode(raw) as List)
          if (row is Map<String, dynamic>) CardCode.fromJson(row),
      ];
    } on Exception {
      return null;
    }
  }

  @override
  Future<void> keep(String orderId, List<CardCode> codes) async {
    if (codes.isEmpty) {
      return;
    }
    await _storage.write(
      key: _key(orderId),
      value: jsonEncode([
        for (final code in codes)
          {'code': code.code, 'serial': code.serial, 'expiry': code.expiry},
      ]),
    );
  }

  @override
  Future<Set<String>> usedCodes() async {
    try {
      final raw = await _storage.read(key: _usedKey);
      return raw == null
          ? <String>{}
          : {...(jsonDecode(raw) as List).whereType<String>()};
    } on Exception {
      return <String>{};
    }
  }

  @override
  Future<void> setUsed(String code, bool used) async {
    final current = await usedCodes();
    used ? current.add(code) : current.remove(code);
    await _storage.write(key: _usedKey, value: jsonEncode(current.toList()));
  }

  /// Forgets this vault's own keys only: the keychain also holds the
  /// sign-in, which clearing codes must never touch.
  @override
  Future<void> clear() async {
    final all = await _storage.readAll();
    for (final key in all.keys.toList()) {
      if (key.startsWith('cards.codes.v1.') || key == _usedKey) {
        await _storage.delete(key: key);
      }
    }
  }
}

class MemoryCodeVault implements CodeVault {
  final Map<String, List<CardCode>> _codes = {};
  final Set<String> _used = {};

  @override
  Future<List<CardCode>?> codes(String orderId) async => _codes[orderId];

  @override
  Future<void> keep(String orderId, List<CardCode> codes) async =>
      _codes[orderId] = codes;

  @override
  Future<Set<String>> usedCodes() async => {..._used};

  @override
  Future<void> setUsed(String code, bool used) async =>
      used ? _used.add(code) : _used.remove(code);

  @override
  Future<void> clear() async {
    _codes.clear();
    _used.clear();
  }
}

/// Face ID / fingerprint in front of saved codes. A device with neither (or
/// the web) is not locked: the codes are its owner's either way. One unlock
/// lasts a few minutes, so looking at three cards asks once.
class CodeLock {
  CodeLock({LocalAuthentication? auth, this.enabled = true, this.settings})
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;
  final bool enabled;

  /// The customer's own switch for the lock, in the account settings.
  final AppSettings? settings;
  DateTime? _unlockedAt;

  static const Duration window = Duration(minutes: 5);

  bool get isUnlocked =>
      !enabled ||
      !(settings?.codeLock ?? true) ||
      (_unlockedAt != null && DateTime.now().difference(_unlockedAt!) < window);

  /// Asks the device. True when the codes may be shown.
  Future<bool> unlock(String reason) async {
    if (isUnlocked || kIsWeb) {
      return true;
    }
    try {
      if (!await _auth.isDeviceSupported()) {
        _unlockedAt = DateTime.now();
        return true;
      }
      final ok = await _auth.authenticate(localizedReason: reason);
      if (ok) {
        _unlockedAt = DateTime.now();
      }
      return ok;
    } on PlatformException {
      // No biometrics enrolled and no device passcode: nothing to check.
      _unlockedAt = DateTime.now();
      return true;
    } on LocalAuthException {
      return false;
    }
  }
}
