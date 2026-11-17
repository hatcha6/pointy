import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The customer's orders as last listed, kept in the keychain beside the
/// codes of their cards: «كروتي» lists them with no network, and each card
/// then shows the code this phone holds. The codes themselves are not here
/// (they are the [CodeVault]'s). The relay can always list the orders again,
/// so losing the vault loses nothing.
abstract class OrdersVault {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

class SecureOrdersVault implements OrdersVault {
  SecureOrdersVault([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'cards.orders.v1';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  /// This vault's own key only: the keychain also holds the sign-in.
  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class MemoryOrdersVault implements OrdersVault {
  String? _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String value) async => _value = value;

  @override
  Future<void> clear() async => _value = null;
}
