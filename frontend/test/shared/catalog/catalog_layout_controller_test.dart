import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/storage/app_key_value_store.dart';
import 'package:pointy_frontend/src/core/storage/key_value_store.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog_layout_controller.dart';

import '../../support/key_value_store_testing.dart';

const _key = 'pos_catalog_layout';

void main() {
  test('a machine that never chose shows cards', () async {
    final controller = CatalogLayoutController(storageKey: _key);
    addTearDown(controller.dispose);

    await controller.loaded;

    expect(controller.layout, CatalogLayout.grid);
  });

  test('opens on the layout this machine chose last time', () async {
    installMemoryKeyValueStore({_key: 'list'});
    final controller = CatalogLayoutController(storageKey: _key);
    addTearDown(controller.dispose);
    var notified = 0;
    controller.addListener(() => notified++);

    await controller.loaded;

    expect(controller.layout, CatalogLayout.list);
    expect(notified, 1);
  });

  test('a value it does not recognise falls back to cards', () async {
    installMemoryKeyValueStore({_key: 'mosaic'});
    final controller = CatalogLayoutController(storageKey: _key);
    addTearDown(controller.dispose);

    await controller.loaded;

    expect(controller.layout, CatalogLayout.grid);
  });

  test('switching shows the table at once and remembers it', () async {
    final store = installMemoryKeyValueStore();
    final controller = CatalogLayoutController(storageKey: _key);
    addTearDown(controller.dispose);
    await controller.loaded;
    var notified = 0;
    controller.addListener(() => notified++);

    final saving = controller.setLayout(CatalogLayout.list);

    // On screen before the write lands, not after.
    expect(controller.layout, CatalogLayout.list);
    expect(notified, 1);
    await saving;
    expect(await store.getString(_key), 'list');

    await controller.setLayout(CatalogLayout.list);
    expect(notified, 1, reason: 'picking the layout already shown is a no-op');
  });

  test('a pick made while the stored choice is loading wins', () async {
    installMemoryKeyValueStore({_key: 'list'});
    final controller = CatalogLayoutController(storageKey: _key);
    addTearDown(controller.dispose);

    // Before the read comes back: the cashier's tap is the newer word.
    await controller.setLayout(CatalogLayout.grid);
    await controller.loaded;

    expect(controller.layout, CatalogLayout.grid);
  });

  test('disposed before the read returns, it stays quiet', () async {
    installMemoryKeyValueStore({_key: 'list'});
    final controller = CatalogLayoutController(storageKey: _key);

    controller.dispose();

    // Would throw "used after being disposed" if it still notified.
    await expectLater(controller.loaded, completes);
  });

  test('storage that fails still leaves a working toggle', () async {
    AppKeyValueStore.debugOverride(_FailingStore());
    final controller = CatalogLayoutController(storageKey: _key);
    addTearDown(controller.dispose);

    await expectLater(controller.loaded, completes);
    expect(controller.layout, CatalogLayout.grid);

    await expectLater(controller.setLayout(CatalogLayout.list), completes);
    expect(controller.layout, CatalogLayout.list);
  });
}

class _FailingStore extends MemoryKeyValueStore {
  @override
  Future<String?> getString(String key) async =>
      throw StateError('database is locked');

  @override
  Future<void> setString(String key, String value) async =>
      throw StateError('database is locked');
}
