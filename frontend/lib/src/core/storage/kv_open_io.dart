import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
// sqflite_common_ffi re-exports the sqflite_common api (DatabaseFactory, ...).
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'local_database.dart';
import 'local_stores.dart';
import 'sqlite_analytics_queue.dart';
import 'sqlite_key_value_store.dart';
import 'storage_migration.dart';

/// Native build: open the one local database, hand out the stores that live in
/// it, and run the one-time migrations. Selected over [kv_open_stub.dart]
/// whenever `dart.library.io` is available (i.e. every non-web platform).
///
/// One connection for both tables, deliberately: a second connection would be a
/// second writer, and writers are what contend for the lock.
Future<LocalStores> openPlatformStores() async {
  final factory = _databaseFactory();
  final dir = await getApplicationSupportDirectory();
  final path = '${dir.path}${Platform.pathSeparator}pointy_store.db';
  final database = await LocalDatabase.open(
    factory: factory,
    path: path,
    schema: const <String>[
      SqliteKeyValueStore.schema,
      SqliteAnalyticsQueue.schema,
    ],
  );
  final keyValue = SqliteKeyValueStore(database);
  final analyticsQueue = SqliteAnalyticsQueue(database);
  await migrateFromSharedPreferences(keyValue);
  // Lift any queue still sitting in the old single-row form into the table.
  await analyticsQueue.migrateLegacyBlob(
    keyValue,
    legacyKey: legacyAnalyticsQueueKey,
    clientEventIdOf: analyticsClientEventIdOf,
  );
  return LocalStores(keyValue: keyValue, analyticsQueue: analyticsQueue);
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
