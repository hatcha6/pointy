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
Future<void> migrateFromSharedPreferences(KeyValueStore store) async {
  try {
    if (await store.getString(kMigratedFromPrefsKey) != null) {
      return;
    }
    // A corrupt legacy file must not throw out of the migration read;
    // quarantine it first (a no-op when healthy) so getInstance() returns an
    // empty store instead of a FormatException.
    await ResilientPreferences.ensureHealthy();
    final prefs = await SharedPreferences.getInstance();
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
    await store.setString(
      kMigratedFromPrefsKey,
      DateTime.now().toUtc().toIso8601String(),
    );
  } catch (error, stackTrace) {
    debugPrint('shared_preferences migration skipped: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}
