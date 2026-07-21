import 'package:flutter/foundation.dart';

import 'key_value_store.dart';
// Conditional import: SQLite on native (dart.library.io), shared_preferences on
// web. Both files expose `openPlatformKeyValueStore()`.
import 'kv_open_stub.dart' if (dart.library.io) 'kv_open_io.dart';

/// Process-wide accessor for the platform [KeyValueStore] — the
/// `SharedPreferences.getInstance()` analogue for the app's durable local store.
///
/// The first call opens the store (FFI init + one-time `shared_preferences`
/// migration + integrity guard on native) and caches it; every later call
/// returns the same instance. Warm it once from `main()` before `runApp` so the
/// first read never races the open. All storage services resolve their backend
/// through [instance].
class AppKeyValueStore {
  AppKeyValueStore._();

  static KeyValueStore? _instance;
  static Future<KeyValueStore>? _pending;

  static Future<KeyValueStore> instance() {
    final existing = _instance;
    if (existing != null) {
      return Future<KeyValueStore>.value(existing);
    }
    return _pending ??= _open();
  }

  static Future<KeyValueStore> _open() async {
    try {
      KeyValueStore store;
      try {
        store = await openPlatformKeyValueStore();
      } catch (error, stackTrace) {
        // The SQLite store already self-heals a corrupt database; this catches
        // the rarer total failures (support dir unavailable, native lib won't
        // load, disk full). Fall back to a non-persistent in-memory store so
        // boot is never blocked — a working app beats a dead one, matching the
        // ResilientPreferences philosophy. Persistence resumes next launch.
        debugPrint('KeyValueStore open failed, using in-memory fallback: $error');
        debugPrintStack(stackTrace: stackTrace);
        store = MemoryKeyValueStore();
      }
      _instance = store;
      return store;
    } finally {
      _pending = null;
    }
  }

  /// Installs an explicit store, bypassing the platform open. Tests use this
  /// (with a [MemoryKeyValueStore]) in place of
  /// `SharedPreferences.setMockInitialValues`.
  @visibleForTesting
  static void debugOverride(KeyValueStore store) {
    _instance = store;
    _pending = null;
  }

  /// Clears the cached instance so the next [instance] call re-opens.
  @visibleForTesting
  static void reset() {
    _instance = null;
    _pending = null;
  }
}
