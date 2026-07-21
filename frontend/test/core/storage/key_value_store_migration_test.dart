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
}
