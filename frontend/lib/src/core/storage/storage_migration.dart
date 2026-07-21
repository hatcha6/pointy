import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../resilient_preferences.dart';
import 'key_value_store.dart';

/// Sentinel written into the SQLite store once the legacy `shared_preferences`
/// values have been copied across, so the migration runs exactly once.
const String kMigratedFromPrefsKey = 'pointy.storage.migrated_from_prefs.v1';

/// Copies any legacy `shared_preferences` values into [store] exactly once, so
/// upgrading a device to the SQLite-backed store never loses its saved state:
/// connection profile, device id, printer/kitchen/theme/price-checker configs,
/// installation id, the analytics queue, and in-flight POS/purchase drafts.
///
/// Best-effort and idempotent: a failure (or a corrupt legacy file) is logged
/// and swallowed rather than blocking boot — the app comes up on whatever made
/// it across, and re-discovers the rest.
///
/// The marker is written into BOTH the store and the legacy file. The store
/// marker is the fast path on every later boot; the legacy-file marker is the
/// one that matters when the SQLite DB is quarantined and rebuilt empty
/// ([SqliteKeyValueStore.open] self-heals a corrupt DB). A rebuilt store has no
/// marker, but the legacy file still sits on disk with its now-stale contents —
/// without the legacy-file marker the migration would run again and resurrect
/// whatever it held at the original upgrade (cleared POS/purchase drafts, an old
/// device id / settings) instead of starting from the recovered store. The
/// legacy marker means "already consumed": we re-stamp the fresh store and skip
/// the re-import.
Future<void> migrateFromSharedPreferences(KeyValueStore store) async {
  try {
    // Fast path: the store already carries the marker (every boot after the
    // first, absent a DB rebuild).
    if (await store.getString(kMigratedFromPrefsKey) != null) {
      return;
    }
    // A corrupt legacy file must not throw out of the migration read;
    // quarantine it first (a no-op when healthy) so getInstance() returns an
    // empty store instead of a FormatException.
    await ResilientPreferences.ensureHealthy();
    final prefs = await SharedPreferences.getInstance();

    // Store marker gone but the legacy file already marked ⇒ the store was
    // rebuilt (quarantine) after a prior migration. The legacy file is stale,
    // so do NOT re-import it; just re-stamp the recovered store so later boots
    // take the fast path again.
    final legacyMarker = prefs.getString(kMigratedFromPrefsKey);
    if (legacyMarker != null) {
      await store.setString(kMigratedFromPrefsKey, legacyMarker);
      return;
    }

    for (final key in prefs.getKeys()) {
      if (key == kMigratedFromPrefsKey) {
        continue;
      }
      final value = prefs.get(key);
      if (value is String) {
        await store.setString(key, value);
      } else if (value is List) {
        await store.setStringList(
          key,
          value.map((e) => e.toString()).toList(growable: false),
        );
      }
      // bool/int/double are never written by this app, so they're skipped.
    }
    final stamp = DateTime.now().toUtc().toIso8601String();
    await store.setString(kMigratedFromPrefsKey, stamp);
    // Mark the legacy file as consumed. Kept (not cleared) so a downgrade can
    // still read its data; best-effort — a torn write just yields a corrupt
    // file that the next boot quarantines to an empty store, which is still
    // safe (nothing stale to resurrect).
    await prefs.setString(kMigratedFromPrefsKey, stamp);
  } catch (error, stackTrace) {
    debugPrint('shared_preferences migration skipped: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}
