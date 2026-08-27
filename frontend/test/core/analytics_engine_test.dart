import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/analytics_engine.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/analytics_event.dart';
import 'package:pointy_frontend/src/data/repositories/analytics_repository.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/analytics_queue_storage.dart';

void main() {
  _registerPacingTests();
  _registerPortedGuardTests();
  test(
    'analytics engine persists failed events and flushes them later',
    () async {
      final sink = _FakeAnalyticsSink(shouldFail: true);
      final storage = MemoryAnalyticsQueueStorage(installationId: 'install-1');
      final engine = AnalyticsEngine(
        sink,
        storage: storage,
        flushInterval: const Duration(hours: 1),
        maxBatchSize: 2,
      );
      engine.setCurrentUser(1); // authenticated: flush is allowed to POST

      await engine.trackUsage(
        AnalyticsEventName.posCheckoutCompleted,
        metrics: const {'total': 12.5},
        flushImmediately: true,
      );

      expect(engine.pendingEventCount, 2);
      // The queue is no longer rewritten once per event (that was holding the
      // SQLite write lock nearly continuously); it is written on a short timer
      // and at every point where losing it would matter. Force the pending
      // write here and check the property that counts: what could not be sent
      // is on disk, not lost.
      await engine.flushPendingWrites();
      expect((await storage.loadEvents()).length, 2);
      // One attempt, not one per event: after a flush fails, the "batch is
      // full" trigger stands down. Left ungated it fires on every subsequent
      // event — a queue that cannot drain sits permanently above maxBatchSize —
      // which is how one client turned a dead ingest endpoint into 5.1M
      // requests, 85% of everything the backend served.
      expect(sink.submittedBatches, hasLength(1));

      sink.shouldFail = false;
      await engine.flush();

      expect(engine.pendingEventCount, 0);
      expect(await storage.loadEvents(), isEmpty);
      expect(sink.acceptedEvents.map((event) => event.installationId).toSet(), {
        'install-1',
      });
      engine.dispose();
    },
  );

  test(
    'analytics engine enriches events with current user and platform',
    () async {
      final sink = _FakeAnalyticsSink();
      final engine = AnalyticsEngine(
        sink,
        storage: MemoryAnalyticsQueueStorage(installationId: 'install-2'),
        flushInterval: const Duration(hours: 1),
      );
      await engine.start();
      engine.setCurrentUser(7);

      await engine.trackUsage(
        AnalyticsEventName.authSessionStarted,
        flushImmediately: true,
      );

      final event = sink.acceptedEvents.last;
      expect(event.attributes['user_id'], 7);
      expect(event.installationId, 'install-2');
      expect(event.deviceId, 'install-2');
      expect(event.platform, startsWith('flutter-'));
      engine.dispose();
    },
  );

  test('analytics engine records interactions with session context', () async {
    final sink = _FakeAnalyticsSink();
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'install-2b'),
      flushInterval: const Duration(hours: 1),
    );
    await engine.start();
    engine.setCurrentUser(11);
    engine.setCurrentScreen('pos');

    await engine.trackInteraction(
      action: 'pointer_up',
      target: 'button',
      attributes: const {'kind': 'touch'},
      metrics: const {'x': 18, 'y': 24},
      flushImmediately: true,
    );

    final event = sink.acceptedEvents.last;
    expect(event.eventType, AnalyticsEventType.usage);
    expect(event.name, 'frontend.interaction');
    expect(event.severity, AnalyticsEventSeverity.debug);
    expect(event.sessionId, isNotEmpty);
    expect(event.installationId, 'install-2b');
    expect(event.attributes['user_id'], 11);
    expect(event.attributes['screen'], 'pos');
    expect(event.attributes['action'], 'pointer_up');
    expect(event.attributes['target'], 'button');
    expect(event.attributes['kind'], 'touch');
    expect(event.metrics['x'], 18);
    expect(event.metrics['y'], 24);
    engine.dispose();
  });

  test('analytics engine records API request performance', () async {
    final sink = _FakeAnalyticsSink();
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'install-3'),
      flushInterval: const Duration(hours: 1),
    );
    await engine.start();
    engine.setCurrentUser(1);

    engine.recordApiRequest(
      const ApiRequestPerformance(
        method: 'GET',
        path: 'products/',
        duration: Duration(milliseconds: 42),
        statusCode: 200,
        responseSizeBytes: 256,
      ),
    );
    await engine.flush();

    final event = sink.acceptedEvents.last;
    expect(event.eventType, AnalyticsEventType.performance);
    expect(event.name, 'frontend.http_request');
    expect(event.severity, AnalyticsEventSeverity.info);
    expect(event.attributes['method'], 'GET');
    expect(event.attributes['path'], 'products/');
    expect(event.attributes['status_family'], '2xx');
    expect(event.metrics['duration_ms'], 42);
    expect(event.metrics['response_size_bytes'], 256);
    engine.dispose();
  });

  test('analytics engine measures custom operations', () async {
    final sink = _FakeAnalyticsSink();
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'install-4'),
      flushInterval: const Duration(hours: 1),
    );
    engine.setCurrentUser(1);

    final result = await engine.measure(
      'catalog.search',
      () async => 'done',
      attributes: const {'screen': 'catalog'},
    );
    await engine.flush();

    expect(result, 'done');
    final event = sink.acceptedEvents.last;
    expect(event.eventType, AnalyticsEventType.performance);
    expect(event.name, 'frontend.operation');
    expect(event.attributes['operation'], 'catalog.search');
    expect(event.attributes['screen'], 'catalog');
    expect(event.metrics['duration_ms'], isA<num>());
    engine.dispose();
  });

  test('nothing is POSTed before sign-in; the backlog ships after', () async {
    final sink = _FakeAnalyticsSink();
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'install-5'),
      flushInterval: const Duration(hours: 1),
    );
    await engine.start();

    // Pre-auth: events queue (and persist) but never hit the network.
    await engine.trackUsage(
      AnalyticsEventName.appStarted,
      flushImmediately: true,
    );
    await engine.flush();
    expect(sink.submittedBatches, isEmpty);
    expect(engine.pendingEventCount, greaterThan(0));

    // Signing in opens the gate; the backlog goes out on the next flush.
    engine.setCurrentUser(9);
    await engine.flush();
    expect(sink.submittedBatches, isNotEmpty);
    expect(engine.pendingEventCount, 0);
    engine.dispose();
  });

  test('frame timings aggregate into one sample per window', () async {
    final sink = _FakeAnalyticsSink();
    var now = DateTime.utc(2026, 7, 20, 9);
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'install-6'),
      flushInterval: const Duration(hours: 1),
      clock: () => now,
      frameTimingWindow: const Duration(seconds: 10),
    );
    await engine.start();
    engine.setCurrentUser(3);

    // Three callbacks inside one window emit nothing yet...
    for (var i = 0; i < 3; i += 1) {
      engine.recordFrameTimings([
        _frame(totalUs: 8000), // smooth
        _frame(totalUs: 45000), // janky (> 32ms)
      ]);
    }
    await engine.flush();
    expect(
      sink.acceptedEvents.where((e) => e.name == 'frontend.frame_timing'),
      isEmpty,
    );

    // ...crossing the window boundary flushes exactly one aggregated sample.
    now = now.add(const Duration(seconds: 11));
    engine.recordFrameTimings([_frame(totalUs: 8000)]);
    await engine.flush();

    final frameEvents = sink.acceptedEvents
        .where((e) => e.name == 'frontend.frame_timing')
        .toList();
    expect(frameEvents, hasLength(1));
    // 3 callbacks x 2 frames + the 1 boundary-crossing frame = 7 frames, of
    // which 3 were janky. Aggregation keeps those counts (and their ratio) exact.
    expect(frameEvents.single.metrics['frame_count'], 7);
    expect(frameEvents.single.metrics['janky_frame_count'], 3);
    expect(frameEvents.single.severity, AnalyticsEventSeverity.warning);
    engine.dispose();
  });

  group('the local store is not rewritten once per event', () {
    test('a burst of events costs one write, not one each', () async {
      final sink = _FakeAnalyticsSink();
      final storage = _CountingQueueStorage();
      var now = DateTime.utc(2026, 8, 27, 9);
      final engine = AnalyticsEngine(
        sink,
        storage: storage,
        flushInterval: const Duration(hours: 1),
        // Pinned so the burst below cannot trip the "batch is full" flush; the
        // two branches ship different defaults.
        maxBatchSize: 500,
        clock: () => now,
        queuePersistInterval: const Duration(seconds: 2),
      );
      await engine.start();
      engine.setCurrentUser(3);
      storage.writes = 0;

      // Persisting per event re-serialised the whole queue (up to 2000 events)
      // and fsync'd it, holding the SQLite write lock nearly continuously.
      await _trackMany(engine, 50);
      expect(
        storage.writes,
        0,
        reason: 'nothing should hit the disk while the burst is still arriving',
      );

      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(storage.writes, 1, reason: 'one insert for the whole burst');
      // 50 tracked, plus the app.started event the engine emits on start().
      expect(await storage.loadEvents(), hasLength(51));
      engine.dispose();
    });

    test('a pending write is forced out before the app can die', () async {
      final sink = _FakeAnalyticsSink(shouldFail: true);
      final storage = _CountingQueueStorage();
      var now = DateTime.utc(2026, 8, 27, 9);
      final engine = AnalyticsEngine(
        sink,
        storage: storage,
        flushInterval: const Duration(hours: 1),
        // Pinned so the burst below cannot trip the "batch is full" flush; the
        // two branches ship different defaults.
        maxBatchSize: 500,
        clock: () => now,
        queuePersistInterval: const Duration(minutes: 5),
      );
      await engine.start();
      engine.setCurrentUser(3);
      storage.writes = 0;

      await _trackMany(engine, 5);
      expect(storage.writes, 0);

      // What the app calls when it leaves the foreground.
      await engine.flushPendingWrites();
      expect(storage.writes, 1);
      expect(await storage.loadEvents(), hasLength(6)); // 5 + app.started

      // And a second call with nothing pending does not write again.
      await engine.flushPendingWrites();
      expect(storage.writes, 1);
      engine.dispose();
    });

    test('a flush still persists what it could not send', () async {
      final sink = _FakeAnalyticsSink(shouldFail: true);
      final storage = _CountingQueueStorage();
      var now = DateTime.utc(2026, 8, 27, 9);
      final engine = AnalyticsEngine(
        sink,
        storage: storage,
        flushInterval: const Duration(hours: 1),
        // Pinned so the burst below cannot trip the "batch is full" flush; the
        // two branches ship different defaults.
        maxBatchSize: 500,
        clock: () => now,
        queuePersistInterval: const Duration(minutes: 5),
      );
      await engine.start();
      engine.setCurrentUser(3);
      await _trackMany(engine, 3);
      storage.writes = 0;

      await engine.flush();
      expect(storage.writes, greaterThanOrEqualTo(1));
      expect(await storage.loadEvents(), hasLength(4)); // 3 + app.started
      engine.dispose();
    });
  });

  test('a screen change closes the frame window it belongs to', () async {
    final sink = _FakeAnalyticsSink();
    var now = DateTime.utc(2026, 8, 27, 9);
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'install-frames'),
      flushInterval: const Duration(hours: 1),
      clock: () => now,
      frameTimingWindow: const Duration(seconds: 10),
    );
    await engine.start();
    engine.setCurrentUser(3);

    // Frames rendered while the dashboard was up...
    engine.setCurrentScreen('dashboard');
    engine.recordFrameTimings([_frame(totalUs: 9000), _frame(totalUs: 9000)]);

    // ...then the user navigates before the 10s window would have expired.
    now = now.add(const Duration(seconds: 3));
    engine.setCurrentScreen('pos');
    engine.recordFrameTimings([_frame(totalUs: 9000)]);
    now = now.add(const Duration(seconds: 11));
    engine.recordFrameTimings([_frame(totalUs: 9000)]);
    await engine.flush();

    final frameEvents = sink.acceptedEvents
        .where((e) => e.name == 'frontend.frame_timing')
        .toList();
    // Two batches, each billed to the screen that actually produced it. Without
    // the flush on navigation both would have landed on 'pos' — every screen
    // charged for the cost of arriving at it.
    expect(frameEvents, hasLength(2));
    expect(frameEvents.first.attributes['screen'], 'dashboard');
    expect(frameEvents.first.metrics['frame_count'], 2);
    expect(frameEvents.last.attributes['screen'], 'pos');
    expect(frameEvents.last.metrics['frame_count'], 2);
    engine.dispose();
  });

  test('dropped frames are measured on the work, not on the wait', () async {
    final sink = _FakeAnalyticsSink();
    var now = DateTime.utc(2026, 8, 27, 9);
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'install-dropped'),
      flushInterval: const Duration(hours: 1),
      clock: () => now,
      frameTimingWindow: const Duration(seconds: 10),
    );
    await engine.start();
    engine.setCurrentUser(3);

    engine.recordFrameTimings([
      // The shape a sleeping machine leaves behind: a frame in flight when the
      // window suspended, reported on resume. 30 seconds of totalSpan against
      // 2ms of build and 4ms of raster — nobody watched anything stutter.
      FrameTiming(
        vsyncStart: 0,
        buildStart: 30000000,
        buildFinish: 30002000,
        rasterStart: 30002000,
        rasterFinish: 30006000,
        rasterFinishWallTime: 30006000,
      ),
      // A real one: raster overran the budget, so this frame was late.
      FrameTiming(
        vsyncStart: 0,
        buildStart: 0,
        buildFinish: 2000,
        rasterStart: 2000,
        rasterFinish: 40000,
        rasterFinishWallTime: 40000,
      ),
    ]);
    now = now.add(const Duration(seconds: 11));
    engine.recordFrameTimings([_frame(totalUs: 8000)]);
    await engine.flush();

    final sample = sink.acceptedEvents
        .firstWhere((e) => e.name == 'frontend.frame_timing')
        .metrics;
    // Both frames clear 32ms of totalSpan, so the old counter calls them janky.
    expect(sample['janky_frame_count'], 2);
    // Only one of them actually missed its budget.
    expect(sample['dropped_frame_count'], 1);
    // And the phase maxima separate the two: an enormous total against an
    // ordinary build and raster is a suspend, not a freeze.
    expect(sample['max_total_ms'], closeTo(30006, 0.001));
    expect(sample['max_build_ms'], closeTo(2, 0.001));
    expect(sample['max_raster_ms'], closeTo(38, 0.001));
    engine.dispose();
  });
}

// totalSpan == rasterFinish - vsyncStart, which the engine uses to classify
// slow (>16ms) / janky (>32ms) frames. Stamps are laid out from 0 so every
// phase duration stays non-negative; build/raster splits don't affect the
// counts this test asserts.
FrameTiming _frame({required int totalUs, int buildUs = 2000}) {
  return FrameTiming(
    vsyncStart: 0,
    buildStart: 0,
    buildFinish: buildUs,
    rasterStart: buildUs,
    rasterFinish: totalUs,
    rasterFinishWallTime: totalUs,
  );
}

Future<void> _trackMany(AnalyticsEngine engine, int count) async {
  for (var index = 0; index < count; index += 1) {
    await engine.trackUsage(AnalyticsEventName.posCheckoutCompleted);
  }
}

/// Counts how many times the queue actually touched storage, which is the
/// thing the coalescing is meant to reduce.
class _CountingQueueStorage extends MemoryAnalyticsQueueStorage {
  _CountingQueueStorage() : super(installationId: 'install-counting');

  int writes = 0;

  @override
  Future<void> appendEvents(List<AnalyticsEventDraft> events) {
    writes += 1;
    return super.appendEvents(events);
  }

  @override
  Future<void> removeEvents(Iterable<String> clientEventIds) {
    writes += 1;
    return super.removeEvents(clientEventIds);
  }

  @override
  Future<void> trimToMostRecent(int maxEvents) {
    writes += 1;
    return super.trimToMostRecent(maxEvents);
  }
}

class _FakeAnalyticsSink implements AnalyticsEventSink {
  _FakeAnalyticsSink({this.shouldFail = false});

  bool shouldFail;
  final List<List<AnalyticsEventDraft>> submittedBatches = [];
  final List<AnalyticsEventDraft> acceptedEvents = [];

  @override
  Future<Result<AnalyticsIngestResult>> ingestEvents(
    List<AnalyticsEventDraft> events,
  ) async {
    submittedBatches.add(List<AnalyticsEventDraft>.of(events));
    if (shouldFail) {
      return Error(Exception('offline'));
    }
    acceptedEvents.addAll(events);
    return Ok(
      AnalyticsIngestResult(
        accepted: events.length,
        duplicates: 0,
        eventIds: events.map((event) => event.clientEventId).toList(),
      ),
    );
  }
}

void _registerPortedGuardTests() {
  test('a kiosk collects nothing it could never ship', () async {
    // Kiosk mode renders instead of the auth gate, so the device never signs in
    // and the ingest endpoint will never accept anything it records.
    final sink = _FakeAnalyticsSink(shouldFail: true);
    final storage = MemoryAnalyticsQueueStorage(installationId: 'kiosk');
    final engine = AnalyticsEngine(
      sink,
      storage: storage,
      flushInterval: const Duration(hours: 1),
      maxBatchSize: 2,
    );
    await engine.start();
    for (var index = 0; index < 5; index += 1) {
      await engine.trackUsage(AnalyticsEventName.posCheckoutCompleted);
    }
    expect(engine.pendingEventCount, greaterThan(0));

    await engine.setCollectionEnabled(false);

    expect(engine.pendingEventCount, 0);
    expect(await storage.loadEvents(), isEmpty);

    for (var index = 0; index < 5; index += 1) {
      await engine.trackUsage(AnalyticsEventName.posCheckoutCompleted);
    }
    expect(engine.pendingEventCount, 0);
    engine.dispose();
  });

  test('a saturated queue does not fire one request per event', () async {
    final sink = _FakeAnalyticsSink(shouldFail: true);
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'runaway'),
      flushInterval: const Duration(hours: 1),
      maxBatchSize: 2,
    );
    engine.setCurrentUser(1);
    await engine.start();
    final afterStart = sink.submittedBatches.length;

    for (var index = 0; index < 50; index += 1) {
      await engine.trackUsage(AnalyticsEventName.posCheckoutCompleted);
    }

    expect(
      sink.submittedBatches.length - afterStart,
      lessThanOrEqualTo(1),
      reason: 'a rejected flush must stand down, not retry once per event',
    );
    engine.dispose();
  });

  test(
    'the API session is told the identity once the engine resolves it',
    () async {
      final identities = <String>[];
      final engine = AnalyticsEngine(
        _FakeAnalyticsSink(),
        storage: MemoryAnalyticsQueueStorage(installationId: 'install-9'),
        flushInterval: const Duration(hours: 1),
        onIdentityResolved: (deviceId, platform) =>
            identities.add('$deviceId/$platform'),
      );

      await engine.start();

      expect(identities, hasLength(1));
      expect(identities.single, startsWith('install-9/'));
      engine.dispose();
    },
  );
}

void _registerPacingTests() {
  test('a burst of events cannot become a burst of requests', () async {
    // The 2026-08-17 incident: telemetry flooding the ingest endpoint took the
    // shop's own traffic to 104-second product-list calls and stopped sales for
    // four minutes. A queue that cannot drain sits above maxBatchSize, so every
    // event re-triggers a flush — without a window the request rate becomes the
    // event rate.
    var now = DateTime.utc(2026, 8, 17, 11, 38);
    final sink = _FakeAnalyticsSink();
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'paced'),
      flushInterval: const Duration(seconds: 15),
      maxBatchSize: 2,
      maxRequestsPerWindow: 3,
      clock: () => now,
    );
    engine.setCurrentUser(1);
    await engine.start();
    sink.submittedBatches.clear();

    for (var index = 0; index < 40; index += 1) {
      await engine.trackUsage(AnalyticsEventName.posCheckoutCompleted);
    }

    expect(sink.submittedBatches.length, lessThanOrEqualTo(3));
    expect(engine.pendingEventCount, greaterThan(0));
    engine.dispose();
  });

  test('successive windows drain the backlog', () async {
    var now = DateTime.utc(2026, 8, 17, 11, 38);
    final sink = _FakeAnalyticsSink();
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'drain'),
      flushInterval: const Duration(seconds: 15),
      maxBatchSize: 5,
      maxRequestsPerWindow: 2,
      clock: () => now,
    );
    engine.setCurrentUser(1);
    await engine.start();
    for (var index = 0; index < 20; index += 1) {
      await engine.trackUsage(AnalyticsEventName.posCheckoutCompleted);
    }

    for (var tick = 0; tick < 15; tick += 1) {
      now = now.add(const Duration(seconds: 15));
      await engine.flush();
    }

    expect(
      engine.pendingEventCount,
      0,
      reason: 'pacing must not mean the backlog never ships',
    );
    engine.dispose();
  });
}
