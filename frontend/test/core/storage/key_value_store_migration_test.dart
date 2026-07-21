import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/storage/key_value_store.dart';
import 'package:pointy_frontend/src/core/storage/storage_migration.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('copies legacy shared_preferences values into the store once', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'pointy.connection.device_id.v1': 'device-abc',
      'device_usage_mode': 'multi_user',
      'pointy.analytics.queue.v1': <String>['{"a":1}', '{"b":2}'],
    });
    final store = MemoryKeyValueStore();

    await migrateFromSharedPreferences(store);

    expect(await store.getString('pointy.connection.device_id.v1'), 'device-abc');
    expect(await store.getString('device_usage_mode'), 'multi_user');
    expect(
      await store.getStringList('pointy.analytics.queue.v1'),
      ['{"a":1}', '{"b":2}'],
    );
    // Sentinel is written so the migration knows it has run.
    expect(await store.getString(kMigratedFromPrefsKey), isNotNull);
  });

  test('is idempotent — a second run never re-copies', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'device_usage_mode': 'multi_user',
    });
    final store = MemoryKeyValueStore();
    await migrateFromSharedPreferences(store);

    // Simulate the app moving on: the store's value diverges from the legacy
    // one, and a new legacy key appears. Neither should be pulled in again.
    await store.setString('device_usage_mode', 'single_user');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'device_usage_mode': 'multi_user',
      'late_key': 'late',
    });

    await migrateFromSharedPreferences(store);

    expect(await store.getString('device_usage_mode'), 'single_user');
    expect(await store.getString('late_key'), isNull);
  });

  test('marks the legacy file so a consumed migration is recorded there too', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'device_usage_mode': 'multi_user',
    });
    final store = MemoryKeyValueStore();

    await migrateFromSharedPreferences(store);

    // The marker lands in the legacy file (not only the store), so it survives
    // a later store rebuild.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kMigratedFromPrefsKey), isNotNull);
  });

  test(
    'a rebuilt (quarantined) store never re-imports the stale legacy file',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'pointy.connection.device_id.v1': 'device-abc',
        'device_usage_mode': 'multi_user',
        'pointy.pos.drafts.v1': <String>['{"draft":"old"}'],
      });

      // First migration into the original store.
      final original = MemoryKeyValueStore();
      await migrateFromSharedPreferences(original);
      expect(await original.getString('device_usage_mode'), 'multi_user');

      // The app runs on; its live state diverges from the legacy file, which
      // now holds stale values (a draft since cleared, an id since rotated) but
      // still sits on disk. Then the SQLite DB is corrupted and rebuilt empty
      // (quarantine): a fresh store with no marker, same legacy file.
      final rebuilt = MemoryKeyValueStore();
      await migrateFromSharedPreferences(rebuilt);

      // The recovered store must NOT resurrect the stale legacy values...
      expect(await rebuilt.getString('device_usage_mode'), isNull);
      expect(await rebuilt.getString('pointy.connection.device_id.v1'), isNull);
      expect(await rebuilt.getStringList('pointy.pos.drafts.v1'), isNull);
      // ...but it is re-stamped so subsequent boots take the fast path again.
      expect(await rebuilt.getString(kMigratedFromPrefsKey), isNotNull);
    },
  );
}
