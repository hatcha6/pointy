import 'package:flutter/foundation.dart';

import '../../core/storage/app_key_value_store.dart';

/// Scopes whose snapshots must never reach the device.
///
/// The learning module hosts the *real* app over a sandbox backend, so the real
/// view models run — and they crash-save the POS cart, the purchase draft and
/// the stock count to local storage keyed by the signed-in user id. That id
/// belongs to a practice cashier who does not exist, so every abandoned lesson
/// left a key behind; worse, a practice cart saved under an id that later
/// collides with a real one is restored into a real till.
///
/// Registering the scope diverts its reads and writes to memory for the life of
/// the process. This is deliberately keyed on the *scope* rather than a
/// process-wide "training mode" flag: the real app is still alive underneath a
/// running lesson, and a global latch would silently swallow its saves too.
abstract final class PracticeStorageScopes {
  /// Practice ids start here. Far above any real row id, and distinctive
  /// enough that [purgeFromDevice] can recognise a leftover key by sight.
  static const int idFloor = 900000;

  static final Set<String> _scopes = <String>{};

  static void register(String scope) => _scopes.add(scope);

  static bool contains(String scope) => _scopes.contains(scope);

  /// Keys written by *earlier* builds, before the diversion existed.
  ///
  /// Matches only `<dotted prefix>.v<n>.<practice id>` — the exact shape
  /// [SharedPreferencesScopedJsonStorage] writes — so it cannot take a real
  /// setting with it. Runs when a lesson starts; there is nothing to schedule
  /// and nothing to migrate.
  static final RegExp _leftoverKey = RegExp(r'^pointy\..+\.v\d+\.(\d+)$');

  static Future<int> purgeFromDevice() async {
    final store = await AppKeyValueStore.instance();
    final keys = await store.getKeys();
    var removed = 0;
    for (final key in keys) {
      final match = _leftoverKey.firstMatch(key);
      final id = match == null ? null : int.tryParse(match.group(1)!);
      if (id != null && id >= idFloor) {
        await store.remove(key);
        removed++;
      }
    }
    return removed;
  }

  @visibleForTesting
  static void debugReset() => _scopes.clear();
}

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

  /// Where a practice scope's snapshots go instead. Keyed the same way, so two
  /// prefixes sharing a scope stay separate here as they do on disk.
  static final Map<String, String> _practice = <String, String>{};

  @override
  Future<String?> load(String scope) async {
    if (PracticeStorageScopes.contains(scope)) {
      final held = _practice[_key(scope)];
      return (held == null || held.isEmpty) ? null : held;
    }
    final store = await AppKeyValueStore.instance();
    final encoded = await store.getString(_key(scope));
    if (encoded == null || encoded.isEmpty) {
      return null;
    }
    return encoded;
  }

  @override
  Future<void> save(String scope, String json) async {
    if (PracticeStorageScopes.contains(scope)) {
      _practice[_key(scope)] = json;
      return;
    }
    final store = await AppKeyValueStore.instance();
    await store.setString(_key(scope), json);
  }

  @override
  Future<void> clear(String scope) async {
    if (PracticeStorageScopes.contains(scope)) {
      _practice.remove(_key(scope));
      return;
    }
    final store = await AppKeyValueStore.instance();
    await store.remove(_key(scope));
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
