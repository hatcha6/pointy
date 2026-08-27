import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqlite_api.dart';

/// The app's one local SQLite connection, and the durability rules that make it
/// safe on a shop PC that loses power without warning.
///
/// Everything the client persists locally lives in this single database file:
/// the key/value settings table and the analytics queue table. One file and one
/// connection is deliberate — a second connection is a second writer, and
/// writers are what contend.
///
/// Three guarantees, in order of how often they matter:
///
/// **Writes survive the outage.** WAL journalling plus `synchronous=FULL` means
/// every commit is fsync'd and an interrupted write rolls back whole, so a power
/// cut can never leave a torn store the way the old `shared_preferences` JSON
/// file could.
///
/// **A lock is waited out, not reported.** See [_busyTimeoutMs].
///
/// **A broken file never stops the app.** [open] quarantines a database that
/// will not open or fails its integrity check and rebuilds empty, so the worst
/// case is losing local convenience state rather than a client that cannot
/// start.
class LocalDatabase {
  LocalDatabase._(this._db);

  final Database _db;

  /// The raw handle, for the store classes in this directory that own a table
  /// in this database. Nothing outside `core/storage` should touch it.
  Database get db => _db;

  /// Suffix marking a quarantined (previously unreadable) database file.
  static const String _quarantineMarker = '.corrupt-';

  /// The SQLite files that make up the store — the DB plus its WAL sidecars.
  static const List<String> _dbSuffixes = <String>['', '-wal', '-shm'];

  /// Keep at most this many quarantined files so a machine that corrupts on
  /// every boot can't accumulate them without bound.
  static const int _quarantineKeepFiles = 9; // ~3 incidents × 3 sidecar files

  /// How long SQLite itself will wait for a lock before giving up.
  ///
  /// This is the difference between "wait a moment" and "database is locked".
  /// Neither `sqflite_common` nor `sqflite_common_ffi` sets a busy timeout, so
  /// the desktop build inherited SQLite's default of **zero**: any writer that
  /// found the file locked failed instantly rather than waiting. That produced
  /// 107 `database is locked` errors in the field, trending upward.
  ///
  /// A lock is normally held for the length of one tiny commit, so a wait this
  /// long is only ever reached by something genuinely stuck — at which point
  /// failing is the honest answer.
  static const int _busyTimeoutMs = 5000;

  /// Cap the WAL's on-disk size after a checkpoint. Without this the sidecar
  /// keeps whatever high-water mark it once reached, which on a till that
  /// writes steadily all day is a file that only ever grows.
  static const int _walSizeLimitBytes = 4 * 1024 * 1024;

  /// Retries for a lock error that survived [_busyTimeoutMs].
  ///
  /// The busy timeout covers ordinary contention. It does *not* cover
  /// `SQLITE_BUSY_SNAPSHOT` — a WAL writer whose read snapshot went stale
  /// because someone else committed first — which SQLite reports immediately
  /// and expects the caller to retry. These few short retries close that gap.
  static const int _maxLockRetries = 3;
  static const Duration _initialLockBackoff = Duration(milliseconds: 25);

  /// How many times a lock error was retried, for diagnostics. A store that is
  /// healthy reports zero; a rising number is the early warning that used to
  /// arrive only as errors.
  int get lockRetries => _lockRetries;
  int _lockRetries = 0;

  /// Opens (creating if needed) the database at [path], applying every
  /// statement in [schema], and recovering from an unreadable file by
  /// quarantining it and starting fresh. Never throws for a corrupt database.
  ///
  /// [schema] must be idempotent (`CREATE TABLE IF NOT EXISTS ...`): it runs on
  /// every open, which is also what creates the tables again after a
  /// quarantine.
  static Future<LocalDatabase> open({
    required DatabaseFactory factory,
    required String path,
    required List<String> schema,
  }) async {
    Database? db;
    try {
      db = await _rawOpen(factory, path);
      await _applySchema(db, schema);
      await _assertHealthy(db);
      return LocalDatabase._(db);
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
      await _applySchema(fresh, schema);
      return LocalDatabase._(fresh);
    }
  }

  static Future<Database> _rawOpen(DatabaseFactory factory, String path) {
    return factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        onConfigure: (db) async {
          // Busy timeout FIRST. Setting the journal mode itself takes a lock,
          // so a second process starting up while the first is mid-write would
          // otherwise fail before it ever got a timeout to wait on.
          await db.rawQuery('PRAGMA busy_timeout=$_busyTimeoutMs');
          // WAL + FULL: no corruption on power loss, and each commit is fsync'd
          // so the write survives the outage. WAL also lets readers run while a
          // write is in flight, which is most of what keeps the two from
          // meeting at all.
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.execute('PRAGMA synchronous=FULL');
          await db.rawQuery('PRAGMA journal_size_limit=$_walSizeLimitBytes');
        },
      ),
    );
  }

  static Future<void> _applySchema(Database db, List<String> schema) async {
    for (final statement in schema) {
      await db.execute(statement);
    }
  }

  static Future<void> _assertHealthy(Database db) async {
    final rows = await db.rawQuery('PRAGMA quick_check');
    final ok =
        rows.length == 1 &&
        rows.first.values.length == 1 &&
        rows.first.values.first?.toString().toLowerCase() == 'ok';
    if (!ok) {
      throw StateError('SQLite quick_check failed: $rows');
    }
  }

  /// Reads back a PRAGMA, so a test can assert the connection was configured
  /// the way this class claims.
  @visibleForTesting
  Future<List<Map<String, Object?>>> debugPragma(String name) {
    return _db.rawQuery('PRAGMA $name');
  }

  /// Closes the connection. The app keeps its singleton open for the whole
  /// process; this is for tests and for stores that own an isolated file.
  Future<void> close() => _db.close();

  /// Runs [action] against this connection, retrying briefly if SQLite reports
  /// the database locked. Every read and write in this directory goes through
  /// here.
  Future<T> guard<T>(Future<T> Function() action) {
    return retryOnLock(action, onRetry: () => _lockRetries += 1);
  }

  /// Runs [action], retrying briefly if SQLite reports the database locked.
  ///
  /// The busy timeout does most of the work; this exists for the lock errors it
  /// cannot cover (see [_maxLockRetries]) and for the ones that resolve the
  /// instant whoever held the lock commits. A lock error that survives all of
  /// this is rethrown rather than swallowed — a read that quietly returned
  /// "absent" would look to the caller like a setting that was never saved, and
  /// the app would helpfully reset it.
  /// The retry itself, separated so it can be tested against injected lock
  /// errors. In-process contention cannot be reproduced on desktop — the ffi
  /// driver funnels every database call through a single isolate behind a
  /// global lock — so the only honest way to exercise this is to hand it the
  /// error directly.
  @visibleForTesting
  static Future<T> retryOnLock<T>(
    Future<T> Function() action, {
    int maxRetries = _maxLockRetries,
    Duration initialBackoff = _initialLockBackoff,
    void Function()? onRetry,
  }) async {
    var backoff = initialBackoff;
    for (var attempt = 1; ; attempt += 1) {
      try {
        return await action();
      } catch (error) {
        // Anything that is not a lock is a real failure and must surface
        // immediately: retrying a schema error or a disk-full just delays the
        // report and hides the cause.
        if (attempt > maxRetries || !_isLockError(error)) {
          rethrow;
        }
        onRetry?.call();
        await Future<void>.delayed(backoff);
        backoff *= 2;
      }
    }
  }

  /// Whether [error] is SQLite refusing because someone else holds the lock.
  ///
  /// Matched on text because that is all the driver surfaces: `sqflite`
  /// wraps the result code in a `DatabaseException` whose message is the
  /// sqlite3 string.
  static bool _isLockError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('database is locked') ||
        message.contains('database table is locked') ||
        message.contains('sqlite_busy') ||
        message.contains('sqlite_locked');
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
      final quarantines =
          dir.listSync().whereType<File>().where((f) {
            final name = _basename(f.path);
            return name.startsWith(base) && name.contains(_quarantineMarker);
          }).toList()..sort(
            (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
          );
      if (quarantines.length <= _quarantineKeepFiles) {
        return;
      }
      for (final stale in quarantines.take(
        quarantines.length - _quarantineKeepFiles,
      )) {
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
