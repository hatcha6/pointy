import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/revalidation.dart';
import 'package:pointy_frontend/src/core/server_state.dart';

void main() {
  late ServerStateNotifier state;
  late Revalidator revalidator;

  setUp(() {
    state = ServerStateNotifier();
    revalidator = Revalidator(state);
    state.apply({'settings': '1', 'catalog_defs': '1', 'stock': '1'});
  });

  tearDown(() => revalidator.dispose());

  test('refreshes when a watched domain moves', () async {
    var refreshes = 0;
    revalidator.watch(
      domains: const {ServerStateDomain.settings},
      debounce: Duration.zero,
      onStale: () async => refreshes++,
    );

    state.apply({'settings': '2'});
    await Future<void>.delayed(Duration.zero);
    expect(refreshes, 1);
  });

  test('ignores domains it does not watch', () async {
    var refreshes = 0;
    revalidator.watch(
      domains: const {ServerStateDomain.settings},
      debounce: Duration.zero,
      onStale: () async => refreshes++,
    );

    state.apply({'stock': '2', 'catalog_defs': '2'});
    await Future<void>.delayed(Duration.zero);
    expect(refreshes, 0);
  });

  test('collapses a burst into one refresh', () async {
    // Stock moves on every sale line in the shop. One refresh, not five.
    var refreshes = 0;
    revalidator.watch(
      domains: const {ServerStateDomain.stock},
      debounce: const Duration(milliseconds: 20),
      onStale: () async => refreshes++,
    );

    for (var i = 2; i <= 6; i++) {
      state.apply({'stock': '$i'});
    }
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(refreshes, 1);
  });

  test('holds a refresh while the gate is closed, then runs it', () async {
    // The cashier is mid-sale. The change is not dropped — it waits.
    var refreshes = 0;
    var busy = true;
    revalidator.watch(
      domains: const {ServerStateDomain.catalogDefs},
      debounce: Duration.zero,
      canRun: () => !busy,
      onStale: () async => refreshes++,
    );

    state.apply({'catalog_defs': '2'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(refreshes, 0, reason: 'must not touch the screen mid-sale');

    busy = false;
    revalidator.gateOpened();
    await Future<void>.delayed(Duration.zero);
    expect(refreshes, 1, reason: 'the held refresh runs once free');
  });

  test('gateOpened does nothing when nothing is pending', () async {
    var refreshes = 0;
    revalidator.watch(
      domains: const {ServerStateDomain.settings},
      debounce: Duration.zero,
      onStale: () async => refreshes++,
    );

    revalidator.gateOpened();
    revalidator.gateOpened();
    await Future<void>.delayed(Duration.zero);
    expect(refreshes, 0);
  });

  test('never runs two refreshes of the same watcher at once', () async {
    var running = 0;
    var maxConcurrent = 0;
    var completed = 0;
    revalidator.watch(
      domains: const {ServerStateDomain.settings},
      debounce: Duration.zero,
      onStale: () async {
        running++;
        maxConcurrent = running > maxConcurrent ? running : maxConcurrent;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        running--;
        completed++;
      },
    );

    state.apply({'settings': '2'});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    state.apply({'settings': '3'});
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(maxConcurrent, 1);
    // The change that landed mid-refresh is not lost: it runs after.
    expect(completed, 2);
  });

  test('a failing refresh is swallowed and does not stop later ones', () async {
    // Stale data on screen beats an error a cashier has to dismiss.
    var attempts = 0;
    revalidator.watch(
      domains: const {ServerStateDomain.settings},
      debounce: Duration.zero,
      onStale: () async {
        attempts++;
        throw Exception('backend is down');
      },
    );

    state.apply({'settings': '2'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    state.apply({'settings': '3'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(attempts, 2);
  });

  test('a cancelled subscription stops refreshing', () async {
    var refreshes = 0;
    final subscription = revalidator.watch(
      domains: const {ServerStateDomain.settings},
      debounce: Duration.zero,
      onStale: () async => refreshes++,
    );

    subscription.cancel();
    state.apply({'settings': '2'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(refreshes, 0);
  });

  test('dispose detaches from the notifier', () async {
    var refreshes = 0;
    revalidator.watch(
      domains: const {ServerStateDomain.settings},
      debounce: Duration.zero,
      onStale: () async => refreshes++,
    );

    revalidator.dispose();
    state.apply({'settings': '2'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(refreshes, 0);
  });

  // A refresh whose own requests move the counter it watches — in the field,
  // the permission refresh re-read the users list, and a backend bug made that
  // read a permission change. Unspaced it ran back to back for an hour.
  test('a self-feeding refresh is spaced, not run back to back', () async {
    state.apply({'permissions': '1'});
    var version = 1;
    var refreshes = 0;
    revalidator.watch(
      domains: const {ServerStateDomain.permissions},
      debounce: Duration.zero,
      minInterval: const Duration(milliseconds: 150),
      onStale: () async {
        refreshes++;
        version++;
        state.apply({'permissions': '$version'});
      },
    );

    state.apply({'permissions': '${++version}'});
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // Runs at ~0, 150, 300 and 450 ms — never hundreds.
    expect(refreshes, inInclusiveRange(2, 4));
  });

  test('spacing does not delay the first refresh', () async {
    state.apply({'permissions': '1'});
    var refreshes = 0;
    revalidator.watch(
      domains: const {ServerStateDomain.permissions},
      debounce: Duration.zero,
      minInterval: const Duration(seconds: 10),
      onStale: () async => refreshes++,
    );

    state.apply({'permissions': '7'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(refreshes, 1);
  });

  test('a change held by spacing still runs once the gap has passed', () async {
    state.apply({'permissions': '1'});
    var refreshes = 0;
    revalidator.watch(
      domains: const {ServerStateDomain.permissions},
      debounce: Duration.zero,
      minInterval: const Duration(milliseconds: 80),
      onStale: () async => refreshes++,
    );

    state.apply({'permissions': '7'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    state.apply({'permissions': '8'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(refreshes, 1, reason: 'too soon: held');

    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(refreshes, 2, reason: 'held, not dropped');
  });
}
