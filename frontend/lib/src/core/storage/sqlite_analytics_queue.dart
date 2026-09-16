import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'key_value_store.dart';
import 'local_database.dart';

/// The pending-telemetry queue, as an actual queue.
///
/// ## What this replaces, and why
///
/// The queue used to be one row in the key/value table holding a JSON array of
/// every pending event. That made each of the three things a queue does
/// expensive and unsafe in the same way:
///
/// * **Appending one event** decoded nothing but re-encoded *everything* — up to
///   2000 events — and wrote the whole blob back under `synchronous=FULL`. O(n)
///   per event, O(n²) per batch, and the SQLite write lock held for the length
///   of it. That is where the field's `database is locked` errors came from.
/// * **Removing the events a flush delivered** meant rewriting the survivors.
/// * **A torn or truncated blob lost the entire queue**, because a single
///   `jsonDecode` failure discards every event in it. One bad byte, everything
///   gone.
///
/// Here each event is a row. Appending inserts rows, delivering deletes rows by
/// id, trimming deletes the oldest, and a row that will not decode costs
/// exactly that row.
///
/// Ordering is by [_columnSeq], an `AUTOINCREMENT` key. Plain rowids are reused
/// after deletes, which on a queue that is constantly drained would eventually
/// hand a new event an id lower than one already waiting and quietly reorder
/// delivery.
class SqliteAnalyticsQueue {
  SqliteAnalyticsQueue(this._database);

  final LocalDatabase _database;

  static const String table = 'analytics_queue';
  static const String _columnSeq = 'seq';
  static const String _columnId = 'client_event_id';
  static const String _columnPayload = 'payload';

  /// DDL for this store's table, handed to [LocalDatabase.open].
  ///
  /// [_columnId] is UNIQUE so a re-append can never double-queue an event: the
  /// insert is `OR IGNORE`, which makes appending idempotent and means a crash
  /// between "written" and "acknowledged" costs nothing.
  static const String schema =
      'CREATE TABLE IF NOT EXISTS $table ('
      '$_columnSeq INTEGER PRIMARY KEY AUTOINCREMENT, '
      '$_columnId TEXT NOT NULL UNIQUE, '
      '$_columnPayload TEXT NOT NULL)';

  /// The [limit] most recent queued payloads, returned oldest first.
  ///
  /// Read newest-first and reversed, rather than simply read in order: a device
  /// that has been unable to deliver holds a backlog whose *oldest* rows are
  /// precisely the ones [trimToMostRecent] exists to discard, so a bare
  /// `ORDER BY seq ASC LIMIT n` would load exactly the wrong n. One till in the
  /// field carried a whole day's telemetry from three weeks earlier and had
  /// still not reached the current week.
  ///
  /// A row whose JSON will not parse is dropped and the rest are returned — the
  /// blob it replaced would have lost the lot.
  Future<List<String>> loadPayloads({int? limit}) async {
    final rows = await _database.guard(
      () => _database.db.query(
        table,
        columns: <String>[_columnPayload],
        orderBy: '$_columnSeq DESC',
        limit: limit != null && limit > 0 ? limit : null,
      ),
    );
    return rows
        .map((row) => row[_columnPayload])
        .whereType<String>()
        .toList(growable: false)
        .reversed
        .toList(growable: false);
  }

  /// Adds [entries] in one transaction, so a burst costs one commit.
  Future<void> append(Iterable<QueuedAnalyticsPayload> entries) async {
    final pending = entries.toList(growable: false);
    if (pending.isEmpty) {
      return;
    }
    await _database.guard(
      () => _database.db.transaction((txn) async {
        for (final entry in pending) {
          await txn.rawInsert(
            'INSERT OR IGNORE INTO $table ($_columnId, $_columnPayload) '
            'VALUES (?, ?)',
            <Object?>[entry.clientEventId, entry.payload],
          );
        }
      }),
    );
  }

  /// Drops the events a flush delivered.
  Future<void> remove(Iterable<String> clientEventIds) async {
    final ids = clientEventIds.toList(growable: false);
    if (ids.isEmpty) {
      return;
    }
    // Chunked: SQLite caps bound variables (999 by default), and a delivered
    // batch is normally well under that but a recovery pass need not be.
    for (var start = 0; start < ids.length; start += _maxVariables) {
      final chunk = ids.sublist(
        start,
        (start + _maxVariables).clamp(0, ids.length),
      );
      final placeholders = List<String>.filled(chunk.length, '?').join(', ');
      await _database.guard(
        () => _database.db.rawDelete(
          'DELETE FROM $table WHERE $_columnId IN ($placeholders)',
          chunk,
        ),
      );
    }
  }

  /// Keeps only the [maxEvents] newest rows, dropping the oldest first — the
  /// same "a full queue sheds history, not news" rule the in-memory queue uses.
  ///
  /// Returns how many rows it discarded, because a device quietly shedding
  /// history is the difference between "this till is idle" and "this till has
  /// been unable to deliver for three weeks", and the two looked identical from
  /// an export.
  Future<int> trimToMostRecent(int maxEvents) async {
    if (maxEvents < 0) {
      return 0;
    }
    return _database.guard(
      () => _database.db.rawDelete(
        'DELETE FROM $table WHERE $_columnSeq NOT IN '
        '(SELECT $_columnSeq FROM $table ORDER BY $_columnSeq DESC LIMIT ?)',
        <Object?>[maxEvents],
      ),
    );
  }

  /// The oldest payload still queued, or null when the queue is empty.
  ///
  /// One row, by index on the primary key. It is read to date the tail of the
  /// backlog — the single number that says whether a device is delivering this
  /// week's telemetry or last month's.
  Future<String?> oldestPayload() async {
    final rows = await _database.guard(
      () => _database.db.query(
        table,
        columns: <String>[_columnPayload],
        orderBy: '$_columnSeq ASC',
        limit: 1,
      ),
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first[_columnPayload] as String?;
  }

  Future<void> clear() async {
    await _database.guard(() => _database.db.delete(table));
  }

  /// How many events are waiting. Cheap, indexed, and the other half of the
  /// backlog question.
  Future<int> count() async {
    final rows = await _database.guard(
      () => _database.db.rawQuery('SELECT COUNT(*) AS n FROM $table'),
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Moves a pre-table queue out of the key/value row it used to live in.
  ///
  /// Runs once: the row is deleted in the same breath, and its absence is the
  /// marker. Best-effort — telemetry that cannot be carried across is not worth
  /// failing a boot for, so a bad blob is dropped rather than retried forever.
  Future<void> migrateLegacyBlob(
    KeyValueStore keyValue, {
    required String legacyKey,
    required String Function(String payload) clientEventIdOf,
  }) async {
    try {
      final encoded = await keyValue.getStringList(legacyKey);
      if (encoded == null) {
        return;
      }
      await append([
        for (final payload in encoded)
          if (clientEventIdOf(payload).isNotEmpty)
            QueuedAnalyticsPayload(
              clientEventId: clientEventIdOf(payload),
              payload: payload,
            ),
      ]);
      await keyValue.remove(legacyKey);
    } catch (error, stackTrace) {
      debugPrint('Legacy analytics queue not migrated: $error');
      debugPrintStack(stackTrace: stackTrace);
      // Drop it rather than leaving a blob that retries (and fails) forever.
      try {
        await keyValue.remove(legacyKey);
      } catch (_) {
        // Nothing further to try.
      }
    }
  }

  /// SQLite's default `SQLITE_MAX_VARIABLE_NUMBER`, less a little headroom.
  static const int _maxVariables = 900;
}

/// One queued event as the queue stores it: an opaque payload plus the id the
/// backend deduplicates on.
@immutable
class QueuedAnalyticsPayload {
  const QueuedAnalyticsPayload({
    required this.clientEventId,
    required this.payload,
  });

  final String clientEventId;
  final String payload;
}

/// Decodes [payload] far enough to find the client event id, or `''`.
String analyticsClientEventIdOf(String payload) {
  try {
    final decoded = jsonDecode(payload);
    if (decoded is Map) {
      return decoded['client_event_id']?.toString() ?? '';
    }
  } on FormatException {
    return '';
  }
  return '';
}
