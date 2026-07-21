import 'key_value_store.dart';
import 'shared_preferences_key_value_store.dart';

/// Web build: browser storage has no torn-write problem, so back the store with
/// `shared_preferences` directly. Selected over [kv_open_io.dart] when
/// `dart.library.io` is unavailable (web). Native builds never load this file.
Future<KeyValueStore> openPlatformKeyValueStore() {
  return SharedPreferencesKeyValueStore.open();
}
