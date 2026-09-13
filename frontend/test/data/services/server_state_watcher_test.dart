import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/server_state.dart';
import 'package:pointy_frontend/src/data/services/server_state_api_client.dart';
import 'package:pointy_frontend/src/data/services/server_state_watcher.dart';

ServerStateSnapshot _snapshot(
  Map<String, String> versions, {
  int interval = 15,
  bool enabled = true,
}) => ServerStateSnapshot(
  versions: versions,
  pollIntervalSeconds: interval,
  enabled: enabled,
);

void main() {
  late ServerStateNotifier state;

  setUp(() => state = ServerStateNotifier());

  test('a poll feeds the vector through to listeners', () async {
    var polls = 0;
    final watcher = ServerStateWatcher(
      state: state,
      initialInterval: const Duration(seconds: 30),
      fetchState: () async {
        polls++;
        return _snapshot({'settings': '${polls + 1}'});
      },
    );
    addTearDown(watcher.dispose);

    state.apply({'settings': '1'});
    watcher.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(polls, 1);
    expect(state.versionOf('settings'), '2');
    expect(watcher.isServerEnabled, isTrue);
  });

  test('the server sets the cadence', () async {
    // So a struggling shop can be slowed down without a client release.
    final watcher = ServerStateWatcher(
      state: state,
      initialInterval: const Duration(seconds: 15),
      fetchState: () async => _snapshot(const {}, interval: 120),
    );
    addTearDown(watcher.dispose);

    watcher.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // Next poll is 120s away, so nothing more fires in this test's lifetime.
    expect(watcher.isServerEnabled, isTrue);
  });

  test(
    'a backend that publishes nothing is reported, not assumed fresh',
    () async {
      // Otherwise a client on a backend with Redis down trusts its caches
      // forever, waiting for a bump that will never come.
      final watcher = ServerStateWatcher(
        state: state,
        fetchState: () async => _snapshot(const {}, enabled: false),
      );
      addTearDown(watcher.dispose);

      watcher.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(watcher.isServerEnabled, isFalse);
    },
  );

  test('a failed poll is swallowed and backs off', () async {
    // A shop whose Wi-Fi dropped must not be asked four times a minute by
    // every till on the floor.
    var polls = 0;
    final watcher = ServerStateWatcher(
      state: state,
      initialInterval: const Duration(milliseconds: 10),
      fetchState: () async {
        polls++;
        throw Exception('offline');
      },
    );
    addTearDown(watcher.dispose);

    watcher.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    // Backing off doubles each time (10ms, 20, 40, 80…), so a tenth of a
    // second buys a handful of attempts rather than a dozen.
    expect(polls, lessThan(6));
    expect(polls, greaterThan(1));
  });

  test('recovering from a failure returns to the normal cadence', () async {
    // The backoff must not be a one-way door: a shop whose network came back
    // has to start hearing about changes again promptly, not every five
    // minutes for the rest of the shift.
    var polls = 0;
    var failing = true;
    final watcher = ServerStateWatcher(
      state: state,
      initialInterval: const Duration(milliseconds: 10),
      fetchState: () async {
        polls++;
        if (failing) {
          throw Exception('offline');
        }
        // interval 0 = "server does not say", so the local cadence stands
        // and this test measures the backoff rather than the server's value.
        return _snapshot({'settings': '$polls'}, interval: 0);
      },
    );
    addTearDown(watcher.dispose);

    watcher.start();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    failing = false;
    // One backed-off wait, one success that resets it, then the base interval.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final afterRecovery = polls;
    expect(state.versionOf('settings'), isNotNull, reason: 'a poll succeeded');

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      polls - afterRecovery,
      greaterThan(2),
      reason: 'back to ~10ms polling, not still backed off',
    );
  });

  test('pausing stops asking and resuming asks straight away', () async {
    var polls = 0;
    final watcher = ServerStateWatcher(
      state: state,
      initialInterval: const Duration(seconds: 30),
      fetchState: () async {
        polls++;
        return _snapshot(const {});
      },
    );
    addTearDown(watcher.dispose);

    watcher.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(polls, 1);

    watcher.pause();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(polls, 1);

    // Coming back is when the screen is most likely stale — don't wait out the
    // interval.
    watcher.resume();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(polls, 2);
  });

  test('stopping means signed out: nothing is asked', () async {
    var polls = 0;
    final watcher = ServerStateWatcher(
      state: state,
      initialInterval: const Duration(milliseconds: 10),
      fetchState: () async {
        polls++;
        return _snapshot(const {});
      },
    );
    addTearDown(watcher.dispose);

    watcher.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    watcher.stop();
    final afterStop = polls;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(polls, afterStop);
    expect(watcher.isServerEnabled, isFalse);
  });

  test('overlapping polls collapse into one', () async {
    var inFlight = 0;
    var maxInFlight = 0;
    final watcher = ServerStateWatcher(
      state: state,
      initialInterval: const Duration(milliseconds: 5),
      fetchState: () async {
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inFlight--;
        return _snapshot(const {});
      },
    );
    addTearDown(watcher.dispose);

    watcher.start();
    await watcher.pollNow();
    await watcher.pollNow();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(maxInFlight, 1);
  });
}
