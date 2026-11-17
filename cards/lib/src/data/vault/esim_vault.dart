import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The customer's eSIMs, with how each installs, kept in the keychain beside
/// the codes of their cards: a traveller who has just landed has no network
/// to read the QR code back with. The relay can always read an eSIM again, so
/// losing the vault loses nothing.
abstract class EsimVault {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

class SecureEsimVault implements EsimVault {
  SecureEsimVault([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'cards.esims.v1';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  /// This vault's own key only: the keychain also holds the sign-in.
  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class MemoryEsimVault implements EsimVault {
  String? _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String value) async => _value = value;

  @override
  Future<void> clear() async => _value = null;
}
