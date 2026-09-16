import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/companion.dart';
import 'package:pointy_frontend/src/data/repositories/companion_repository.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/companion/companion_bridge.dart';

const tillKey = 'device-test';

CompanionDevice device({bool paused = false, bool live = true}) =>
    CompanionDevice(id: 1, label: 'iPhone', isPaused: paused, isLive: live);

String scanFrame(int id, String value) => jsonEncode({
  'id': id,
  'kind': 'scan',
  'payload': {'value': value},
});

/// Drives the bridge without HTTP: the stream is a controller the test pushes
/// frames into, so reconnection and degradation are exercised for real rather
/// than mocked away.
class FakeCompanionRepository extends CompanionRepository {
  FakeCompanionRepository() : super(PosApiService());

  List<CompanionDevice> devices = [device()];
  final List<StreamController<SseEvent>> controllers = [];
  int streamOpens = 0;
  int pollCalls = 0;
  CompanionEventPage pollPage = const CompanionEventPage(cursor: 0, events: []);

  /// When set, opening a stream fails immediately — the "backend is down" case.
  bool failStreams = false;

  StreamController<SseEvent> get latest => controllers.last;

  int deviceLoads = 0;

  @override
  Future<Result<List<CompanionDevice>>> loadDevices(String key) async {
    deviceLoads++;
    return Ok(devices);
  }

  @override
  Stream<SseEvent> openStream({required String tillKey, int since = 0}) {
    streamOpens++;
    final controller = StreamController<SseEvent>();
    controllers.add(controller);
    if (failStreams) {
      controller.addError(StateError('stream refused'));
    }
    return controller.stream;
  }

  @override
  Future<Result<CompanionEventPage>> loadEvents({
    required String tillKey,
    int since = 0,
  }) async {
    pollCalls++;
    return Ok(pollPage);
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late FakeCompanionRepository repository;
  late CompanionBridge bridge;

  setUp(() {
    repository = FakeCompanionRepository();
    bridge = CompanionBridge(
      repository: repository,
      tillKey: tillKey,
      pollInterval: const Duration(milliseconds: 20),
      // Deterministic: the test asserts on behaviour, not on how long the
      // production backoff happens to take.
      retryBackoff: Duration.zero,
    );
  });

  tearDown(() {
    bridge.dispose();
    for (final controller in repository.controllers) {
      if (!controller.isClosed) controller.close();
    }
  });

  test('nothing is held open when no phone is paired', () async {
    repository.devices = [];

    await bridge.start();
    await settle();

    expect(repository.streamOpens, 0);
    expect(bridge.status.value.state, CompanionLinkState.idle);
  });

  test(
    'the pairing sheet holds the channel open with no phone paired',
    () async {
      repository.devices = [];
      await bridge.start();

      bridge.boost();
      await settle();

      expect(repository.streamOpens, 1);
    },
  );

  test('a paired phone opens the stream and reports itself live', () async {
    await bridge.start();
    repository.latest.add(const SseEvent(event: 'ready', data: '{"cursor":0}'));
    await settle();

    expect(repository.streamOpens, 1);
    expect(bridge.status.value.state, CompanionLinkState.live);
    expect(bridge.status.value.hasDevice, isTrue);
  });

  test('a scan is delivered as a plain barcode value', () async {
    await bridge.start();
    await settle();
    final scans = <String>[];
    bridge.scans.listen(scans.add);

    repository.latest.add(
      SseEvent(event: 'companion', data: scanFrame(7, '6001234500001')),
    );
    await settle();

    expect(scans, ['6001234500001']);
  });

  test('a planned reconnect re-opens without counting as a failure', () async {
    await bridge.start();
    await settle();

    repository.latest.add(
      const SseEvent(event: 'reconnect', data: '{"cursor":12}'),
    );
    await settle();

    expect(repository.streamOpens, 2);
    expect(bridge.status.value.state, isNot(CompanionLinkState.polling));
  });

  test('a scan is never replayed after a reconnect', () async {
    await bridge.start();
    await settle();
    final scans = <String>[];
    bridge.scans.listen(scans.add);

    repository.latest.add(
      SseEvent(event: 'companion', data: scanFrame(3, 'A')),
    );
    await settle();
    repository.latest.add(
      const SseEvent(event: 'reconnect', data: '{"cursor":3}'),
    );
    await settle();
    // The replacement stream replays from the server's side; the bridge must
    // drop anything at or below the cursor it already delivered.
    repository.latest.add(
      SseEvent(event: 'companion', data: scanFrame(4, 'B')),
    );
    await settle();

    expect(scans, ['A', 'B']);
  });

  test(
    'a stream that keeps failing degrades to polling instead of dying',
    () async {
      repository.failStreams = true;
      repository.pollPage = const CompanionEventPage(cursor: 0, events: []);

      await bridge.start();
      // Three consecutive failures is the documented threshold.
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(repository.streamOpens, greaterThanOrEqualTo(3));
      expect(repository.pollCalls, greaterThan(0));
    },
  );

  test('polling still delivers a scan', () async {
    repository.failStreams = true;
    repository.pollPage = CompanionEventPage(
      cursor: 9,
      events: [
        CompanionEvent.fromJson(
          jsonDecode(scanFrame(9, 'POLLED')) as Map<String, Object?>,
        ),
      ],
    );
    final scans = <String>[];
    bridge.scans.listen(scans.add);

    await bridge.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(scans, contains('POLLED'));
  });

  test('the last phone leaving closes the channel', () async {
    await bridge.start();
    await settle();
    expect(repository.streamOpens, 1);

    repository.devices = [];
    await bridge.refreshDevices();
    await settle();

    expect(bridge.status.value.state, CompanionLinkState.idle);
    expect(bridge.status.value.hasDevice, isFalse);
  });

  test('a paused phone is reported as paused', () async {
    repository.devices = [device(paused: true)];

    await bridge.start();
    await settle();

    expect(bridge.status.value.isPaused, isTrue);
  });

  group('how often the roster is re-read', () {
    /// A bridge whose two refresh rates are far enough apart that a test can
    /// tell which one it chose: anything using the pairing rate fires many
    /// times inside [settle], anything using the paired rate fires not at all.
    CompanionBridge rateBridge() => CompanionBridge(
      repository: repository,
      tillKey: tillKey,
      pollInterval: const Duration(milliseconds: 20),
      pairingRefreshInterval: const Duration(milliseconds: 20),
      pairedRefreshInterval: const Duration(seconds: 5),
      retryBackoff: Duration.zero,
    );

    Future<void> waitForSeveralTicks() =>
        Future<void>.delayed(const Duration(milliseconds: 150));

    test('an idle till asks once and then stops asking', () async {
      // The bug this pins: one shop polled this endpoint 9,481 times in a week
      // for a single pairing, and between 03:00 and 07:00 — shop shut, tills
      // idle — those polls were 100% of the backend's traffic. Nothing can add
      // a phone except a pairing this till issues, so there is nothing to see.
      repository.devices = [];
      bridge.dispose();
      bridge = rateBridge();

      await bridge.start();
      await waitForSeveralTicks();

      expect(repository.deviceLoads, 1, reason: 'the one read at startup');
    });

    test('the pairing sheet is what starts it asking', () async {
      repository.devices = [];
      bridge.dispose();
      bridge = rateBridge();
      await bridge.start();

      bridge.boost();
      await waitForSeveralTicks();

      expect(repository.deviceLoads, greaterThan(2));
    });

    test('closing the pairing sheet stops it again', () async {
      repository.devices = [];
      bridge.dispose();
      bridge = rateBridge();
      await bridge.start();
      bridge.boost();
      await waitForSeveralTicks();

      bridge.endBoost();
      final afterSheet = repository.deviceLoads;
      await waitForSeveralTicks();

      expect(repository.deviceLoads, afterSheet);
    });

    test('a paired phone is watched slowly, not at the pairing rate', () async {
      // Slowly, but not never: a device whose register session closed stops
      // being live on the server without anything being emitted, so asking is
      // the only way the till finds out.
      bridge.dispose();
      bridge = rateBridge();

      await bridge.start();
      await waitForSeveralTicks();

      expect(repository.deviceLoads, 1);
    });

    test('a phone whose shift ended holds nothing open', () async {
      repository.devices = [device(live: false)];
      bridge.dispose();
      bridge = rateBridge();

      await bridge.start();
      await waitForSeveralTicks();

      expect(bridge.status.value.hasDevice, isFalse);
      expect(repository.streamOpens, 0, reason: 'it cannot scan any more');
      expect(repository.deviceLoads, 1, reason: 'and nothing more can change');
    });
  });
}
