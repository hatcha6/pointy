import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/storage/app_key_value_store.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/features/learning/sandbox/sandbox_shop.dart';
import 'package:pointy_frontend/src/features/learning/sandbox/seeds/grocery_morning.dart';

import '../support/key_value_store_testing.dart';

/// The practice shop must leave nothing on the device.
///
/// The real view models run inside a lesson — that is the whole point of the
/// design — and they crash-save the cart, the purchase draft and the stock
/// count to local storage keyed by the signed-in user. Under a practice
/// cashier those keys are litter at best, and at worst a practice cart waiting
/// to be restored into a real till.
void main() {
  const pos = SharedPreferencesScopedJsonStorage('pointy.pos.sessions.v1');

  test('a practice scope never reaches the device', () async {
    final store = installMemoryKeyValueStore();
    final shop = groceryMorningSeed();
    final scope = '${shop.cashierId}';

    await pos.save(scope, '{"carts":[1]}');

    expect(
      await store.getKeys(),
      isEmpty,
      reason: 'a practice cart was written to the device',
    );
    // Still readable within the run: the app must behave normally inside the
    // lesson, it just must not outlive it.
    expect(await pos.load(scope), '{"carts":[1]}');
  });

  test('a real scope still reaches the device', () async {
    final store = installMemoryKeyValueStore();

    await pos.save('7', '{"carts":[2]}');

    expect(await store.getKeys(), contains('pointy.pos.sessions.v1.7'));
    expect(await pos.load('7'), '{"carts":[2]}');
  });

  test('every id a practice run hands out is diverted, not just the cashier', () {
    // A stock count keys its un-submitted entry by the *count session* id, not
    // the user — so the sandbox has to allocate that from the same sequence or
    // practice keypad entries land under a real count's id.
    final id = nextPracticeId();
    expect(PracticeStorageScopes.contains('$id'), isTrue);
    expect(id, greaterThan(PracticeStorageScopes.idFloor));
  });

  test('leftovers from earlier builds are swept, real keys are not', () async {
    final store = installMemoryKeyValueStore({
      'pointy.pos.sessions.v1.900001': '{"carts":[]}',
      'pointy.purchase.draft.v1.900002': '{}',
      'pointy.pos.sessions.v1.7': '{"carts":[]}',
      'pointy.printing.calibration.v1': '{}',
      'pointy.connection.profile.v2.8000': '{}',
    });

    final removed = await PracticeStorageScopes.purgeFromDevice();

    expect(removed, 2);
    expect(await store.getKeys(), <String>{
      'pointy.pos.sessions.v1.7',
      'pointy.printing.calibration.v1',
      // A real key whose last segment happens to be a number is left alone:
      // the sweep only takes ids above the practice floor.
      'pointy.connection.profile.v2.8000',
    });
  });

  test('the store is still the store when nothing is registered', () async {
    AppKeyValueStore.reset();
    installMemoryKeyValueStore();
    expect(PracticeStorageScopes.contains('900001'), isTrue);
    expect(PracticeStorageScopes.contains('1'), isFalse);
  });
}
