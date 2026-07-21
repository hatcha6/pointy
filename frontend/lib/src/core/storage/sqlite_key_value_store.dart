import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'key_value_store.dart';

/// SQLite-backed [KeyValueStore] for native platforms.
///
/// Every value lives in a single `kv(key, value, type)` table. Writes are
/// atomic, fsync'd SQLite transactions (WAL journal, `synchronous=FULL`), so a
/// power cut mid-write can never leave a torn store the way the old
/// `shared_preferences` JSON file could — an interrupted write is rolled back
/// whole and committed writes survive the outage.
///
/// [open] is also self-healing: a database that won't open or fails an
/// integrity check is quarantined aside (for post-mortem) and recreated empty,
/// so a damaged store can never stop the app from starting — the same guarantee
/// `ResilientPreferences` gives the legacy file. The only thing lost is local
/// convenience state, which is re-discovered or re-entered.
class SqliteKeyValueStore implements KeyValueStore {
  SqliteKeyValueStore._(this._db);

  final Database _db;

  static const String _table = 'kv';
  static const String _typeString = 's';
  static const String _typeStringList = 'sl';

  /// Suffix marking a quarantined (previously unreadable) database file.
  static const String _quarantineMarker = '.corrupt-';

  /// The SQLite files that make up the store — the DB plus its WAL sidecars.
  static const List<String> _dbSuffixes = <String>['', '-wal', '-shm'];

  /// Keep at most this many quarantined files so a machine that corrupts on
  /// every boot can't accumulate them without bound.
  static const int _quarantineKeepFiles = 9; // ~3 incidents × 3 sidecar files

  /// Opens (creating if needed) the store at [path] using [factory], recovering
  /// from an unreadable database by quarantining it and starting fresh. Never
  /// throws for a corrupt store.
  static Future<SqliteKeyValueStore> open({
    required DatabaseFactory factory,
    required String path,
  }) async {
    Database? db;
    try {
      db = await _rawOpen(factory, path);
      await _ensureSchema(db);
      await _assertHealthy(db);
      return SqliteKeyValueStore._(db);
    } catch (error, stackTrace) {
      // Treat an unreadable DB like a corrupt shared_preferences file: move it
      // aside and rebuild empty so boot never blocks.
      debugPrint('SQLite store failed to open, recovering: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (db != null) {
        try {
          await db.close();
        } catch (_) {
          // Best effort — we're about to move the file aside regardless.
        }
      }
      _quarantine(path);
      final fresh = await _rawOpen(factory, path);
      await _ensureSchema(fresh);
      return SqliteKeyValueStore._(fresh);
    }
  }

  static Future<Database> _rawOpen(DatabaseFactory factory, String path) {
    return factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        onConfigure: (db) async {
          // WAL + FULL: no corruption on power loss, and each commit is fsync'd
          // so the write survives the outage. Writes are tiny and infrequent,
          // so the durability cost is irrelevant.
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.execute('PRAGMA synchronous=FULL');
        },
      ),
    );
  }

  static Future<void> _ensureSchema(Database db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS $_table ('
      'key TEXT PRIMARY KEY NOT NULL, '
      'value TEXT NOT NULL, '
      "type TEXT NOT NULL DEFAULT '$_typeString')",
    );
  }

  static Future<void> _assertHealthy(Database db) async {
    final rows = await db.rawQuery('PRAGMA quick_check');
    final ok = rows.length == 1 &&
        rows.first.values.length == 1 &&
        rows.first.values.first?.toString().toLowerCase() == 'ok';
    if (!ok) {
      throw StateError('SQLite quick_check failed: $rows');
    }
  }

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
    await _db.rawDelete('DELETE FROM $_table WHERE key = ?', <Object?>[key]);
  }

  @override
  Future<Set<String>> getKeys() async {
    final rows = await _db.query(_table, columns: <String>['key']);
    return rows.map((row) => row['key'] as String).toSet();
  }

  /// Closes the underlying database. Exposed for tests; the app keeps the
  /// process-lifetime singleton open.
  @visibleForTesting
  Future<void> close() => _db.close();

  Future<Map<String, Object?>?> _readRow(String key) async {
    final rows = await _db.query(
      _table,
      columns: <String>['value', 'type'],
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> _write(String key, String value, String type) async {
    await _db.rawInsert(
      'INSERT OR REPLACE INTO $_table (key, value, type) VALUES (?, ?, ?)',
      <Object?>[key, value, type],
    );
  }

  /// Renames the store (and its `-wal`/`-shm` sidecars) to timestamped
  /// `.corrupt-*` siblings, deleting instead if the rename fails, then prunes
  /// old quarantines.
  static void _quarantine(String path) {
    final int stamp = DateTime.now().millisecondsSinceEpoch;
    for (final suffix in _dbSuffixes) {
      final file = File('$path$suffix');
      if (!file.existsSync()) {
        continue;
      }
      final target = '$path$suffix$_quarantineMarker$stamp';
      try {
        file.renameSync(target);
      } catch (_) {
        try {
          file.deleteSync();
        } catch (_) {
          // Leftover file is harmless; the fresh DB overwrites the live name.
        }
      }
    }
    _pruneQuarantines(path);
  }

  static void _pruneQuarantines(String path) {
    try {
      final dbFile = File(path);
      final Directory dir = dbFile.parent;
      final String base = _basename(path);
      final quarantines = dir
          .listSync()
          .whereType<File>()
          .where((f) {
            final name = _basename(f.path);
            return name.startsWith(base) && name.contains(_quarantineMarker);
          })
          .toList()
        ..sort(
          (a, b) =>
              a.lastModifiedSync().compareTo(b.lastModifiedSync()),
        );
      if (quarantines.length <= _quarantineKeepFiles) {
        return;
      }
      for (final stale
          in quarantines.take(quarantines.length - _quarantineKeepFiles)) {
        try {
          stale.deleteSync();
        } catch (_) {
          // Best effort.
        }
      }
    } catch (error) {
      debugPrint('Could not prune quarantined SQLite stores: $error');
    }
  }

  static String _basename(String path) {
    final int index = path.lastIndexOf(Platform.pathSeparator);
    return index == -1 ? path : path.substring(index + 1);
  }
}
