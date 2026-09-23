import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/device_settings_storage_service.dart';
import 'package:pointy_frontend/src/shared/product_search/product_search_mode_controller.dart';

import '../../support/key_value_store_testing.dart';

void main() {
  test('the picker is off on a machine nobody has set up', () async {
    final controller = ProductSearchModeController();
    addTearDown(controller.dispose);

    await controller.load();

    expect(controller.pickerEnabled, isFalse);
  });

  test('turning it on is remembered by the next start', () async {
    final store = installMemoryKeyValueStore();
    final controller = ProductSearchModeController();
    addTearDown(controller.dispose);
    var notified = 0;
    controller.addListener(() => notified++);

    expect(await controller.setPickerEnabled(true), isTrue);

    expect(controller.pickerEnabled, isTrue);
    expect(notified, 1);
    expect(await store.getString('product_search_mode_picker'), 'true');

    final nextStart = ProductSearchModeController();
    addTearDown(nextStart.dispose);
    await nextStart.load();
    expect(nextStart.pickerEnabled, isTrue);
  });

  test('a save that fails puts the switch back', () async {
    final controller = ProductSearchModeController(
      storage: const _FailingStorage(),
    );
    addTearDown(controller.dispose);

    expect(await controller.setPickerEnabled(true), isFalse);

    expect(controller.pickerEnabled, isFalse);
  });

  test('a storage failure at startup leaves the picker off', () async {
    final controller = ProductSearchModeController(
      storage: const _FailingStorage(),
    );
    addTearDown(controller.dispose);

    await controller.load();

    expect(controller.pickerEnabled, isFalse);
  });
}

class _FailingStorage extends DeviceSettingsStorageService {
  const _FailingStorage();

  @override
  Future<bool> loadProductSearchModePicker() async =>
      throw StateError('storage unavailable');

  @override
  Future<void> saveProductSearchModePicker(bool enabled) async =>
      throw StateError('storage unavailable');
}
