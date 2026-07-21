import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
