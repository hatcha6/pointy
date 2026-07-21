import 'package:shared_preferences/shared_preferences.dart';

import 'key_value_store.dart';

/// [KeyValueStore] backed by `shared_preferences`.
///
/// This is the **web** backend — browser storage isn't subject to the
/// power-loss torn-write problem that motivated the SQLite store — and the
/// **migration source** on native, read once to copy a device's legacy state
/// into the new SQLite store on upgrade.
class SharedPreferencesKeyValueStore implements KeyValueStore {
  SharedPreferencesKeyValueStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<SharedPreferencesKeyValueStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    return SharedPreferencesKeyValueStore(prefs);
  }

  @override
  Future<String?> getString(String key) async => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) async {
    await _prefs.setString(key, value);
  }

  @override
  Future<List<String>?> getStringList(String key) async =>
      _prefs.getStringList(key);

  @override
  Future<void> setStringList(String key, List<String> value) async {
    await _prefs.setStringList(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _prefs.remove(key);
  }

  @override
  Future<Set<String>> getKeys() async => _prefs.getKeys();
}
