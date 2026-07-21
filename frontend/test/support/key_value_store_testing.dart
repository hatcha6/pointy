import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/storage/app_key_value_store.dart';
import 'package:pointy_frontend/src/core/storage/key_value_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Replaces the platform (SQLite) [AppKeyValueStore] with a fresh in-memory one
/// seeded with [initial], so unit and widget tests never touch native SQLite
/// (which has no plugin registration under `flutter test`).
///
/// This is the KeyValueStore-era replacement for
/// `SharedPreferences.setMockInitialValues` — it seeds the store the app now
/// actually reads. The SharedPreferences mock is primed too, for any residual
/// legacy read (e.g. the one-time migration). Returns the store for read-back
/// assertions.
MemoryKeyValueStore installMemoryKeyValueStore([
  Map<String, Object> initial = const <String, Object>{},
]) {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(initial);
  final store = MemoryKeyValueStore(initial);
  AppKeyValueStore.debugOverride(store);
  return store;
}
