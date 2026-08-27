import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'key_value_store.dart';
import 'local_database.dart';

/// SQLite-backed [KeyValueStore]: the app's settings, profiles and snapshots.
///
/// Every value lives in a single `kv(key, value, type)` table inside the shared
/// [LocalDatabase], which owns the connection and the durability rules (WAL,
/// fsync'd commits, lock waiting, corruption recovery).
///
/// This holds *settings* — things read occasionally and written when a person
/// changes something. Anything append-heavy wants a table of its own rather
/// than a row here: see `SqliteAnalyticsQueue`.
class SqliteKeyValueStore implements KeyValueStore {
  SqliteKeyValueStore(this._database);

  final LocalDatabase _database;

  static const String table = 'kv';
  static const String _typeString = 's';
  static const String _typeStringList = 'sl';

  /// DDL for this store's table, handed to [LocalDatabase.open].
  static const String schema =
      'CREATE TABLE IF NOT EXISTS $table ('
      'key TEXT PRIMARY KEY NOT NULL, '
      'value TEXT NOT NULL, '
      "type TEXT NOT NULL DEFAULT '$_typeString')";

  /// Opens a database at [path] holding only this store. The app opens the
  /// shared database once instead (see `openPlatformStores`); this is for tests
  /// and for callers that genuinely want an isolated file.
  static Future<SqliteKeyValueStore> open({
    required DatabaseFactory factory,
    required String path,
  }) async {
    final database = await LocalDatabase.open(
      factory: factory,
      path: path,
      schema: const <String>[schema],
    );
    return SqliteKeyValueStore(database);
  }

  /// How many times a lock error was retried, for diagnostics.
  int get lockRetries => _database.lockRetries;

  @override
  Future<String?> getString(String key) async {
    final row = await _readRow(key);
    if (row == null || row['type'] != _typeString) {
      return null;
    }
    final value = row['value'];
    return value is String ? value : null;
  }

  @override
  Future<void> setString(String key, String value) async {
    await _write(key, value, _typeString);
  }

  @override
  Future<List<String>?> getStringList(String key) async {
    final row = await _readRow(key);
    if (row == null || row['type'] != _typeStringList) {
      return null;
    }
    final value = row['value'];
    if (value is! String) {
      return null;
    }
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) {
        return null;
      }
      return decoded.map((e) => e.toString()).toList(growable: false);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> setStringList(String key, List<String> value) async {
    await _write(key, jsonEncode(value), _typeStringList);
  }

  @override
  Future<void> remove(String key) async {
    await _database.guard(
      () => _database.db.rawDelete(
        'DELETE FROM $table WHERE key = ?',
        <Object?>[key],
      ),
    );
  }

  @override
  Future<Set<String>> getKeys() async {
    final rows = await _database.guard(
      () => _database.db.query(table, columns: <String>['key']),
    );
    return rows.map((row) => row['key'] as String).toSet();
  }

  /// Closes the underlying database. Exposed for tests; the app keeps the
  /// process-lifetime singleton open.
  @visibleForTesting
  Future<void> close() => _database.close();

  Future<Map<String, Object?>?> _readRow(String key) async {
    final rows = await _database.guard(
      () => _database.db.query(
        table,
        columns: <String>['value', 'type'],
        where: 'key = ?',
        whereArgs: <Object?>[key],
        limit: 1,
      ),
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> _write(String key, String value, String type) async {
    await _database.guard(
      () => _database.db.rawInsert(
        'INSERT OR REPLACE INTO $table (key, value, type) VALUES (?, ?, ?)',
        <Object?>[key, value, type],
      ),
    );
  }
}
