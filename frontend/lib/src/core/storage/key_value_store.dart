/// A tiny key/value persistence primitive — the low-level store that every
/// local setting, profile, and crash-recovery snapshot in the app funnels
/// through.
///
/// The surface is intentionally minimal: it exposes only what the app actually
/// uses (`String` and `List<String>` values). On native platforms it is backed
/// by SQLite (`SqliteKeyValueStore`), whose atomic, fsync'd commits survive the
/// power outages that used to corrupt the old `shared_preferences` JSON file and
/// take the whole app down. On web it is backed by `shared_preferences`
/// (browser storage has no torn-write problem). Resolve the platform default
/// through `AppKeyValueStore.instance`.
///
/// A key holds exactly one kind of value at a time: writing a string clears any
/// list previously stored under that key and vice-versa, and a typed getter
/// returns `null` when the stored value is of the other kind — mirroring
/// `shared_preferences`' own type-mismatch behavior so call sites port over
/// unchanged.
abstract class KeyValueStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<List<String>?> getStringList(String key);
  Future<void> setStringList(String key, List<String> value);
  Future<void> remove(String key);

  /// Every stored key. Used by the one-time `shared_preferences` migration and
  /// by diagnostics; not part of the app's hot path.
  Future<Set<String>> getKeys();
}

/// In-memory [KeyValueStore] for tests and the dev preview harness. Install it
/// with `AppKeyValueStore.debugOverride`.
class MemoryKeyValueStore implements KeyValueStore {
  /// Seeds the store from a plain map (`String` or `List<String>` values),
  /// mirroring `SharedPreferences.setMockInitialValues`.
  MemoryKeyValueStore([Map<String, Object?>? initial]) {
    if (initial == null) {
      return;
    }
    initial.forEach((key, value) {
      if (value is String) {
        _strings[key] = value;
      } else if (value is List) {
        _lists[key] = value.map((e) => e.toString()).toList();
      }
    });
  }

  final Map<String, String> _strings = <String, String>{};
  final Map<String, List<String>> _lists = <String, List<String>>{};

  @override
  Future<String?> getString(String key) async => _strings[key];

  @override
  Future<void> setString(String key, String value) async {
    _lists.remove(key);
    _strings[key] = value;
  }

  @override
  Future<List<String>?> getStringList(String key) async {
    final value = _lists[key];
    return value == null ? null : List<String>.of(value);
  }

  @override
  Future<void> setStringList(String key, List<String> value) async {
    _strings.remove(key);
    _lists[key] = List<String>.of(value);
  }

  @override
  Future<void> remove(String key) async {
    _strings.remove(key);
    _lists.remove(key);
  }

  @override
  Future<Set<String>> getKeys() async => <String>{
    ..._strings.keys,
    ..._lists.keys,
  };
}
