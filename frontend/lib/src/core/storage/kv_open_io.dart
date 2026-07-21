import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
// sqflite_common_ffi re-exports the sqflite_common api (DatabaseFactory, ...).
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'key_value_store.dart';
import 'sqlite_key_value_store.dart';
import 'storage_migration.dart';

/// Native build: open the durable SQLite store and run the one-time
/// `shared_preferences` migration. Selected over [kv_open_stub.dart] whenever
/// `dart.library.io` is available (i.e. every non-web platform).
Future<KeyValueStore> openPlatformKeyValueStore() async {
  final factory = _databaseFactory();
  final dir = await getApplicationSupportDirectory();
  final path = '${dir.path}${Platform.pathSeparator}pointy_store.db';
  final store = await SqliteKeyValueStore.open(factory: factory, path: path);
  await migrateFromSharedPreferences(store);
  return store;
}

/// Desktop uses the bundled sqlite3 via FFI; the `sqflite` plugin is mobile-only
/// (and unregistered on Windows/Linux/macOS), so its factory serves Android/iOS.
DatabaseFactory _databaseFactory() {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }
  return sqflite.databaseFactory;
}
