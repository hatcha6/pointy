import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/storage/app_key_value_store.dart';
import 'package:pointy_frontend/src/core/storage/key_value_store.dart';
import 'package:pointy_frontend/src/features/pos/view_models/services_novelty_controller.dart';

import '../../../support/key_value_store_testing.dart';

/// «جديد» is for a month: a badge that never goes away stops meaning anything.
void main() {
  late DateTime now;

  ServicesNoveltyController controller() =>
      ServicesNoveltyController(clock: () => now);

  setUp(() => now = DateTime(2026, 10, 8, 10));

  test('nothing is new until what was stored has been read', () async {
    final novelty = controller();
    expect(novelty.isNew('airtime'), isFalse, reason: 'no flash of a badge');

    await novelty.loaded;

    expect(novelty.isNew('airtime'), isTrue);
    novelty.dispose();
  });

  test(
    'a service is new from the day it is first shown, for thirty days',
    () async {
      final novelty = controller();
      await novelty.loaded;

      await novelty.markSeen(['airtime', 'electricity']);

      now = DateTime(2026, 11, 6, 23);
      expect(novelty.isNew('airtime'), isTrue, reason: '29 days later');
      now = DateTime(2026, 11, 7, 10);
      expect(novelty.isNew('airtime'), isFalse, reason: '30 days later');
      expect(novelty.isNew('electricity'), isFalse);
      expect(novelty.isNew('water'), isTrue, reason: 'never shown: still new');
      novelty.dispose();
    },
  );

  test('is counted from the first showing, not the latest', () async {
    final novelty = controller();
    await novelty.loaded;
    await novelty.markSeen(['airtime']);

    now = DateTime(2026, 11, 1);
    await novelty.markSeen(['airtime']);

    now = DateTime(2026, 11, 8);
    expect(novelty.isNew('airtime'), isFalse);
    novelty.dispose();
  });

  test('is remembered by the till across restarts', () async {
    final first = controller();
    await first.loaded;
    await first.markSeen(['airtime']);
    first.dispose();

    now = DateTime(2026, 11, 20);
    final second = controller();
    await second.loaded;

    expect(second.isNew('airtime'), isFalse);
    expect(second.isNew('water'), isTrue);
    second.dispose();
  });

  group('a till whose storage fails', () {
    test('still works for the session, and never throws', () async {
      AppKeyValueStore.debugOverride(_BrokenStore());
      final novelty = controller();
      await novelty.loaded;

      expect(novelty.isNew('airtime'), isTrue);
      await novelty.markSeen(['airtime']);
      now = DateTime(2026, 12, 25);
      expect(novelty.isNew('airtime'), isFalse, reason: 'held in memory');
      novelty.dispose();
    });

    test('does not overwrite what it could not read', () async {
      final real = installMemoryKeyValueStore({
        'pos_services_first_seen': '{"airtime":"2026-09-01T09:00:00.000"}',
      });
      AppKeyValueStore.debugOverride(_ReadFailsStore(real));
      final novelty = controller();
      await novelty.loaded;

      await novelty.markSeen(['airtime', 'water']);

      expect(
        await real.getString('pos_services_first_seen'),
        '{"airtime":"2026-09-01T09:00:00.000"}',
        reason: 'a transient read error must not wipe the old dates',
      );
      novelty.dispose();
    });

    test('ignores a stored value that is not what it wrote', () async {
      installMemoryKeyValueStore({'pos_services_first_seen': 'not json'});
      final novelty = controller();
      await novelty.loaded;

      expect(novelty.isNew('airtime'), isTrue);
      await novelty.markSeen(['airtime']);
      expect(novelty.isNew('airtime'), isTrue);
      novelty.dispose();
    });
  });
}

/// A store that cannot be read or written at all.
class _BrokenStore extends MemoryKeyValueStore {
  @override
  Future<String?> getString(String key) => Future.error(StateError('disk'));

  @override
  Future<void> setString(String key, String value) =>
      Future.error(StateError('disk'));
}

/// A store that cannot be read, but takes writes.
class _ReadFailsStore extends MemoryKeyValueStore {
  _ReadFailsStore(this.inner);

  final MemoryKeyValueStore inner;

  @override
  Future<String?> getString(String key) => Future.error(StateError('locked'));

  @override
  Future<void> setString(String key, String value) =>
      inner.setString(key, value);
}
