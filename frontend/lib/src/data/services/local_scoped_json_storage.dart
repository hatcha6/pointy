import 'package:shared_preferences/shared_preferences.dart';

/// A small key/value store for a single JSON payload, namespaced by an opaque
/// [scope] string (typically the signed-in user id) so one device shared by
/// several users never leaks one user's saved state to another.
///
/// Used for crash-recovery snapshots of in-progress work (the POS cart, the
/// purchase draft). The payload is an opaque JSON string owned by the caller.
abstract class ScopedJsonStorage {
  Future<String?> load(String scope);
  Future<void> save(String scope, String json);
  Future<void> clear(String scope);
}

class SharedPreferencesScopedJsonStorage implements ScopedJsonStorage {
  const SharedPreferencesScopedJsonStorage(this.prefix);

  /// Versioned, dotted key prefix, e.g. `pointy.pos.sessions.v1`.
  final String prefix;

  String _key(String scope) => '$prefix.$scope';

  @override
  Future<String?> load(String scope) async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_key(scope));
    if (encoded == null || encoded.isEmpty) {
      return null;
    }
    return encoded;
  }

  @override
  Future<void> save(String scope, String json) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_key(scope), json);
  }

  @override
  Future<void> clear(String scope) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_key(scope));
  }
}

/// In-memory double for tests and the dev preview harness.
class MemoryScopedJsonStorage implements ScopedJsonStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> load(String scope) async => _store[scope];

  @override
  Future<void> save(String scope, String json) async => _store[scope] = json;

  @override
  Future<void> clear(String scope) async => _store.remove(scope);
}
