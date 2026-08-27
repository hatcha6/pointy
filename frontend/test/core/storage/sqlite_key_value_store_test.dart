import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/storage/local_database.dart';
import 'package:pointy_frontend/src/core/storage/sqlite_key_value_store.dart';
// sqflite_common_ffi re-exports the sqflite_common api (DatabaseFactory).
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;
  late DatabaseFactory dbFactory;

  setUpAll(() {
    sqfliteFfiInit();
    dbFactory = databaseFactoryFfi;
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sqlite_kv_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  String dbPath() => '${tempDir.path}${Platform.pathSeparator}store.db';

  Future<SqliteKeyValueStore> openStore([String? path]) {
    return SqliteKeyValueStore.open(factory: dbFactory, path: path ?? dbPath());
  }

  test('SQLite is told to wait for a lock, not to give up', () async {
    // Neither sqflite_common nor sqflite_common_ffi sets a busy timeout, so
    // without this the desktop build inherits SQLite's default of zero and any
    // contention is an instant `database is locked`.
    final database = await LocalDatabase.open(
      factory: dbFactory,
      path: dbPath(),
      schema: const <String>[SqliteKeyValueStore.schema],
    );
    final rows = await database.debugPragma('busy_timeout');
    expect(rows.first.values.first, greaterThanOrEqualTo(1000));

    final limit = await database.debugPragma('journal_size_limit');
    expect(limit.first.values.first, greaterThan(0));
    await database.close();
  });

  test('two connections to one file stay consistent', () async {
    // Not a contention test — the ffi driver serialises every call in a
    // process, so two connections here cannot actually collide. What this does
    // check is that a second connection (in the field: a second process, or an
    // Android client's thread pool) opening and writing the same file finds a
    // sane schema and sees the other's writes.
    final path = dbPath();
    final a = await openStore(path);
    final b = await openStore(path);

    await Future.wait<void>([
      for (var i = 0; i < 20; i += 1) a.setString('a$i', 'from-a-$i'),
      for (var i = 0; i < 20; i += 1) b.setString('b$i', 'from-b-$i'),
    ]);

    expect(await a.getString('b19'), 'from-b-19');
    expect(await b.getString('a19'), 'from-a-19');
    expect((await a.getKeys()).length, 40);
    expect(a.lockRetries, 0);
    await a.close();
    await b.close();
  });

  group('a locked database is waited out, not reported', () {
    test('retries until the lock clears', () async {
      var attempts = 0;
      var retries = 0;
      final value = await LocalDatabase.retryOnLock<String>(
        () async {
          attempts += 1;
          if (attempts < 3) {
            throw StateError('database is locked (code 5 SQLITE_BUSY)');
          }
          return 'written';
        },
        initialBackoff: Duration.zero,
        onRetry: () => retries += 1,
      );
      expect(value, 'written');
      expect(attempts, 3);
      expect(retries, 2);
    });

    test('gives up rather than hanging forever', () async {
      var attempts = 0;
      await expectLater(
        LocalDatabase.retryOnLock<void>(
          () async {
            attempts += 1;
            throw StateError('database is locked');
          },
          maxRetries: 2,
          initialBackoff: Duration.zero,
        ),
        throwsA(isA<StateError>()),
      );
      expect(attempts, 3, reason: 'the first try plus two retries');
    });

    test('a failure that is not a lock is not retried', () async {
      // Retrying a real fault (bad SQL, disk full) would only delay the report
      // and bury the cause.
      var attempts = 0;
      await expectLater(
        LocalDatabase.retryOnLock<void>(() async {
          attempts += 1;
          throw StateError('no such table: kv');
        }, initialBackoff: Duration.zero),
        throwsA(isA<StateError>()),
      );
      expect(attempts, 1);
    });
  });

  test('round-trips strings and string lists', () async {
    final store = await openStore();
    await store.setString('a', 'hello');
    await store.setStringList('b', const ['x', 'y', 'z']);

    expect(await store.getString('a'), 'hello');
    expect(await store.getStringList('b'), ['x', 'y', 'z']);
    expect(await store.getKeys(), {'a', 'b'});

    await store.remove('a');
    expect(await store.getString('a'), isNull);
    expect(await store.getKeys(), {'b'});
    await store.close();
  });

  test('typed getters return null on a type mismatch', () async {
    final store = await openStore();
    await store.setString('s', 'plain');
    expect(await store.getStringList('s'), isNull);

    await store.setStringList('l', const ['a']);
    expect(await store.getString('l'), isNull);

    // Overwriting a string with a list flips the stored type cleanly.
    await store.setStringList('s', const ['now', 'list']);
    expect(await store.getString('s'), isNull);
    expect(await store.getStringList('s'), ['now', 'list']);
    await store.close();
  });

  test('committed writes survive a reopen (durability)', () async {
    final path = dbPath();
    final store = await openStore(path);
    await store.setString('device_id', 'device-123');
    await store.setStringList('queue', const ['{"a":1}']);
    await store.close();

    final reopened = await openStore(path);
    expect(await reopened.getString('device_id'), 'device-123');
    expect(await reopened.getStringList('queue'), ['{"a":1}']);
    await reopened.close();
  });

  test(
    'recovers from a corrupt database by quarantining it and starting empty',
    () async {
      final path = dbPath();
      // Garbage where the DB header should be — what a power cut can leave.
      File(path).writeAsBytesSync(List<int>.filled(4096, 0x7f));

      final store = await openStore(path);
      // Boots clean instead of throwing; the store is usable and empty.
      expect(await store.getKeys(), isEmpty);
      await store.setString('fresh', 'ok');
      expect(await store.getString('fresh'), 'ok');
      await store.close();

      // The corrupt bytes were preserved aside for post-mortem, not discarded.
      final quarantined = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('store.db.corrupt-'))
          .toList();
      expect(quarantined, isNotEmpty);
    },
  );
}
