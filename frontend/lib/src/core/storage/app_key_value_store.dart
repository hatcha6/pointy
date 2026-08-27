import 'package:flutter/foundation.dart';

import 'key_value_store.dart';
import 'local_stores.dart';
import 'sqlite_analytics_queue.dart';
// Conditional import: SQLite on native (dart.library.io), shared_preferences on
// web. Both files expose `openPlatformStores()`.
import 'kv_open_stub.dart' if (dart.library.io) 'kv_open_io.dart';

/// Opens the platform's local persistence once and caches it.
///
/// The first call does the real work (FFI init, schema, integrity guard, the
/// one-time migrations) and every later call reuses it. Warm it once from
/// `main()` before `runApp` so the first read never races the open.
Future<LocalStores> _openOnce() {
  final existing = _stores;
  if (existing != null) {
    return Future<LocalStores>.value(existing);
  }
  return _pending ??= _open();
}

LocalStores? _stores;
Future<LocalStores>? _pending;

Future<LocalStores> _open() async {
  try {
    LocalStores stores;
    try {
      stores = await openPlatformStores();
    } catch (error, stackTrace) {
      // The database already self-heals a corrupt file; this catches the rarer
      // total failures (support dir unavailable, native lib won't load, disk
      // full). Fall back to non-persistent storage so boot is never blocked — a
      // working app beats a dead one. Persistence resumes next launch.
      debugPrint('Local storage open failed, using in-memory fallback: $error');
      debugPrintStack(stackTrace: stackTrace);
      stores = LocalStores(
        keyValue: MemoryKeyValueStore(),
        analyticsQueue: null,
      );
    }
    _stores = stores;
    return stores;
  } finally {
    _pending = null;
  }
}

/// Process-wide accessor for the platform [KeyValueStore] — the
/// `SharedPreferences.getInstance()` analogue for the app's durable local
/// settings. All storage services resolve their backend through [instance].
class AppKeyValueStore {
  AppKeyValueStore._();

  static KeyValueStore? _override;

  static Future<KeyValueStore> instance() {
    final override = _override;
    if (override != null) {
      return Future<KeyValueStore>.value(override);
    }
    return _openOnce().then((stores) => stores.keyValue);
  }

  /// Installs an explicit store, bypassing the platform open. Tests use this
  /// (with a [MemoryKeyValueStore]) in place of
  /// `SharedPreferences.setMockInitialValues`.
  @visibleForTesting
  static void debugOverride(KeyValueStore store) {
    _override = store;
  }

  /// Clears the cached instance so the next [instance] call re-opens.
  @visibleForTesting
  static void reset() {
    _override = null;
    _stores = null;
    _pending = null;
  }
}

/// Process-wide accessor for the pending-telemetry queue table.
///
/// Native only: on web there is no SQLite, and the queue keeps its old
/// single-entry form (see `KeyValueAnalyticsQueueStorage`). [isAvailable] says
/// which world you are in.
class AppAnalyticsQueue {
  AppAnalyticsQueue._();

  static Future<bool> isAvailable() async {
    return (await _openOnce()).analyticsQueue != null;
  }

  static Future<SqliteAnalyticsQueue> instance() async {
    final queue = (await _openOnce()).analyticsQueue;
    if (queue == null) {
      throw StateError(
        'No analytics queue table on this platform; use '
        'KeyValueAnalyticsQueueStorage instead.',
      );
    }
    return queue;
  }
}
