import 'local_stores.dart';
import 'shared_preferences_key_value_store.dart';

/// Web build: browser storage has no torn-write problem and no shop till
/// driving it, so back the key/value store with `shared_preferences` and leave
/// the queue in its single-entry form. Selected over [kv_open_io.dart] when
/// `dart.library.io` is unavailable (web). Native builds never load this file.
Future<LocalStores> openPlatformStores() async {
  final keyValue = await SharedPreferencesKeyValueStore.open();
  return LocalStores(keyValue: keyValue, analyticsQueue: null);
}
