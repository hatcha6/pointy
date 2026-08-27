import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/storage/local_database.dart';
import 'package:pointy_frontend/src/core/storage/sqlite_analytics_queue.dart';
import 'package:pointy_frontend/src/core/storage/sqlite_key_value_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The queue used to be a single JSON array in one key/value row, which made
/// appending O(n), removing O(n), and one bad byte fatal to the whole backlog.
/// These pin the properties a table gives instead.
void main() {
  late Directory tempDir;
  late DatabaseFactory dbFactory;
  late LocalDatabase database;
  late SqliteAnalyticsQueue queue;

  setUpAll(() {
    sqfliteFfiInit();
    dbFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('analytics_queue_test');
    database = await LocalDatabase.open(
      factory: dbFactory,
      path: '${tempDir.path}${Platform.pathSeparator}store.db',
      schema: const <String>[
        SqliteKeyValueStore.schema,
        SqliteAnalyticsQueue.schema,
      ],
    );
    queue = SqliteAnalyticsQueue(database);
  });

  tearDown(() async {
    await database.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  QueuedAnalyticsPayload entry(int i) => QueuedAnalyticsPayload(
    clientEventId: 'evt-$i',
    payload: '{"client_event_id":"evt-$i","name":"e$i"}',
  );

  test('keeps delivery order across appends', () async {
    await queue.append([entry(1), entry(2)]);
    await queue.append([entry(3)]);

    expect(await queue.loadPayloads(), [
      entry(1).payload,
      entry(2).payload,
      entry(3).payload,
    ]);
  });

  test('appending the same event twice queues it once', () async {
    // A crash between "written" and "acknowledged" replays the append; the
    // unique client id is what makes that free.
    await queue.append([entry(1), entry(2)]);
    await queue.append([entry(2), entry(3)]);

    expect(await queue.count(), 3);
  });

  test('delivered events are deleted, the rest are untouched', () async {
    await queue.append([for (var i = 0; i < 5; i += 1) entry(i)]);
    await queue.remove(['evt-1', 'evt-3']);

    expect(await queue.loadPayloads(), [
      entry(0).payload,
      entry(2).payload,
      entry(4).payload,
    ]);
  });

  test('removing ids that are not queued is harmless', () async {
    await queue.append([entry(1)]);
    await queue.remove(['nope', 'evt-1', 'also-nope']);
    expect(await queue.count(), 0);
  });

  test('a full queue sheds the oldest, not the newest', () async {
    await queue.append([for (var i = 0; i < 10; i += 1) entry(i)]);
    await queue.trimToMostRecent(4);

    expect(await queue.loadPayloads(), [
      entry(6).payload,
      entry(7).payload,
      entry(8).payload,
      entry(9).payload,
    ]);
  });

  test('order survives a drained-and-refilled queue', () async {
    // The reason seq is AUTOINCREMENT: plain rowids are reused after deletes,
    // so a queue that is constantly drained would eventually hand a new event
    // an id below one already waiting and quietly reorder delivery.
    await queue.append([for (var i = 0; i < 5; i += 1) entry(i)]);
    await queue.remove([for (var i = 0; i < 5; i += 1) 'evt-$i']);
    await queue.append([entry(100), entry(101)]);

    expect(await queue.loadPayloads(), [
      entry(100).payload,
      entry(101).payload,
    ]);
  });

  test('one unreadable row costs one event, not the backlog', () async {
    await queue.append([
      entry(1),
      const QueuedAnalyticsPayload(
        clientEventId: 'evt-torn',
        payload: '{"client_event_id":"evt-torn", TORN',
      ),
      entry(2),
    ]);

    // The row is still returned as a payload — decoding is the caller's job —
    // but the point is that the other two are here at all. As one JSON array,
    // a single bad byte discarded every event in the queue.
    expect(await queue.loadPayloads(), hasLength(3));
    expect(await queue.count(), 3);
  });

  test('handles a removal larger than SQLite\'s variable limit', () async {
    await queue.append([for (var i = 0; i < 1200; i += 1) entry(i)]);
    await queue.remove([for (var i = 0; i < 1200; i += 1) 'evt-$i']);
    expect(await queue.count(), 0);
  });

  group('migrating the pre-table queue', () {
    test('lifts a legacy blob into the table and drops the row', () async {
      final keyValue = SqliteKeyValueStore(database);
      await keyValue.setStringList('legacy.queue', [
        entry(1).payload,
        entry(2).payload,
      ]);

      await queue.migrateLegacyBlob(
        keyValue,
        legacyKey: 'legacy.queue',
        clientEventIdOf: analyticsClientEventIdOf,
      );

      expect(await queue.count(), 2);
      expect(await keyValue.getStringList('legacy.queue'), isNull);
    });

    test('a blob it cannot read is dropped, not retried forever', () async {
      final keyValue = SqliteKeyValueStore(database);
      await keyValue.setStringList('legacy.queue', ['not json at all']);

      await queue.migrateLegacyBlob(
        keyValue,
        legacyKey: 'legacy.queue',
        clientEventIdOf: analyticsClientEventIdOf,
      );

      expect(await queue.count(), 0);
      expect(await keyValue.getStringList('legacy.queue'), isNull);
    });

    test('does nothing when there is no legacy queue', () async {
      final keyValue = SqliteKeyValueStore(database);
      await queue.migrateLegacyBlob(
        keyValue,
        legacyKey: 'legacy.queue',
        clientEventIdOf: analyticsClientEventIdOf,
      );
      expect(await queue.count(), 0);
    });
  });

  test('the queue and the settings table share one connection', () async {
    // One file, one writer: a second connection would be a second writer, and
    // writers are what contend for the lock.
    final keyValue = SqliteKeyValueStore(database);
    await Future.wait<void>([
      queue.append([entry(1)]),
      keyValue.setString('setting', 'value'),
    ]);

    expect(await queue.count(), 1);
    expect(await keyValue.getString('setting'), 'value');
    expect(keyValue.lockRetries, 0);
  });
}
