import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/analytics_engine.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/analytics_event.dart';
import 'package:pointy_frontend/src/data/repositories/analytics_repository.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/analytics_queue_storage.dart';

void main() {
  _registerRunawayTests();
  _registerBacklogDrainTests();
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

  test('a flush drains the whole queue in backend-sized chunks', () async {
    final sink = _FakeAnalyticsSink();
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'install-3'),
      flushInterval: const Duration(hours: 1),
      maxBatchSize: 100,
    );
    engine.setCurrentUser(1); // authenticated before start: the appStarted
    await engine.start(); //     startup event ships and is cleared below
    sink.submittedBatches.clear();

    for (var i = 0; i < 250; i += 1) {
      await engine.track(
        AnalyticsEventDraft.usage(
          AnalyticsEventName.frontendInteraction,
          occurredAt: DateTime.now().toUtc(),
        ),
      );
    }
    // Two full chunks auto-flushed at the 100-event threshold; the remainder
    // ships in ONE further flush cycle — never one request per timer tick.
    await engine.flush();

    expect(engine.pendingEventCount, 0);
    expect(sink.submittedBatches.length, 3);
    expect(sink.submittedBatches[0], hasLength(100));
    expect(sink.submittedBatches[1], hasLength(100));
    expect(sink.submittedBatches[2], hasLength(50));
    engine.dispose();
  });

  test(
    'immediate flushes are rate-limited so error storms stay batched',
    () async {
      final sink = _FakeAnalyticsSink();
      var now = DateTime.utc(2026, 7, 6, 12);
      final engine = AnalyticsEngine(
        sink,
        storage: MemoryAnalyticsQueueStorage(installationId: 'install-4'),
        flushInterval: const Duration(hours: 1),
        clock: () => now,
        minImmediateFlushGap: const Duration(seconds: 30),
      );
      await engine.start();
      engine.setCurrentUser(1);
      sink.submittedBatches.clear();

      await engine.captureError(Exception('first'), null);
      expect(sink.submittedBatches, hasLength(1));

      // A second error 5 seconds later queues instead of flushing.
      now = now.add(const Duration(seconds: 5));
      await engine.captureError(Exception('second'), null);
      expect(sink.submittedBatches, hasLength(1));
      expect(engine.pendingEventCount, 1);

      // Past the gap, the immediate path opens again.
      now = now.add(const Duration(seconds: 31));
      await engine.captureError(Exception('third'), null);
      expect(sink.submittedBatches, hasLength(2));
      expect(engine.pendingEventCount, 0);
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

void _registerRunawayTests() {
  group('a failing ingest endpoint cannot become a request storm', () {
    test('a saturated queue does not fire one request per event', () async {
      // The field failure, in miniature: shipping is rejected, so the queue
      // never drains and stays above maxBatchSize forever. Before the backoff
      // every new event re-triggered the "batch is full" flush, so the request
      // rate became the event rate — flat, unbounded, around the clock.
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

      await _trackMany(engine, 50);

      expect(
        sink.submittedBatches.length - afterStart,
        lessThanOrEqualTo(1),
        reason: 'a rejected flush must stand down, not retry once per event',
      );
      expect(
        engine.pendingEventCount,
        greaterThan(2),
        reason: 'the events are kept, they are just not each worth a request',
      );
      engine.dispose();
    });

    test('the backoff lifts once it expires', () async {
      var now = DateTime.utc(2026, 8, 26, 12);
      final sink = _FakeAnalyticsSink(shouldFail: true);
      final engine = AnalyticsEngine(
        sink,
        storage: MemoryAnalyticsQueueStorage(installationId: 'backoff'),
        flushInterval: const Duration(hours: 1),
        maxBatchSize: 2,
        clock: () => now,
        initialFlushBackoff: const Duration(seconds: 30),
      );
      engine.setCurrentUser(1);
      await engine.start();
      await _trackMany(engine, 4);
      final duringBackoff = sink.submittedBatches.length;

      now = now.add(const Duration(minutes: 5));
      sink.shouldFail = false;
      await _trackMany(engine, 2);

      expect(
        sink.submittedBatches.length,
        greaterThan(duringBackoff),
        reason: 'once the backoff expires the engine must try again on its own',
      );
      // Whatever is left is a partial batch waiting for the next timer tick,
      // which is the normal batching behaviour rather than a stuck queue.
      expect(engine.pendingEventCount, lessThan(2));
      engine.dispose();
    });

    test(
      'signing in clears a backoff earned by the previous identity',
      () async {
        var now = DateTime.utc(2026, 8, 26, 12);
        final sink = _FakeAnalyticsSink(shouldFail: true);
        final engine = AnalyticsEngine(
          sink,
          storage: MemoryAnalyticsQueueStorage(installationId: 'relogin'),
          flushInterval: const Duration(hours: 1),
          maxBatchSize: 2,
          clock: () => now,
          initialFlushBackoff: const Duration(minutes: 30),
        );
        engine.setCurrentUser(1);
        await engine.start();
        await _trackMany(engine, 4);
        final beforeLogin = sink.submittedBatches.length;

        // A rejection is usually about credentials; new ones deserve a fresh try
        // rather than serving out the old identity's penalty.
        sink.shouldFail = false;
        engine.setCurrentUser(2);
        await _trackMany(engine, 2);

        expect(sink.submittedBatches.length, greaterThan(beforeLogin));
        engine.dispose();
      },
    );
  });

  group('release builds are identifiable', () {
    test('events carry the build they came from', () async {
      // Every one of the 4M frontend events in the first client's dump had an
      // empty app_version, so no field regression could be tied to a release.
      // The value comes from --dart-define=POINTY_VERSION at build time.
      final sink = _FakeAnalyticsSink();
      final engine = AnalyticsEngine(
        sink,
        storage: MemoryAnalyticsQueueStorage(installationId: 'versioned'),
        flushInterval: const Duration(hours: 1),
        appVersion: '0.4.3',
      );
      engine.setCurrentUser(3);
      await engine.start();

      await engine.trackUsage(AnalyticsEventName.posCheckoutCompleted);
      await engine.flush();

      expect(sink.acceptedEvents.map((event) => event.appVersion).toSet(), {
        '0.4.3',
      });
      engine.dispose();
    });

    test('an unbuilt run claims no version at all', () async {
      final sink = _FakeAnalyticsSink();
      final engine = AnalyticsEngine(
        sink,
        storage: MemoryAnalyticsQueueStorage(installationId: 'unversioned'),
        flushInterval: const Duration(hours: 1),
        appVersion: '',
      );
      engine.setCurrentUser(3);
      await engine.start();

      await engine.trackUsage(AnalyticsEventName.posCheckoutCompleted);
      await engine.flush();

      expect(
        sink.acceptedEvents.every((event) => event.appVersion == null),
        isTrue,
        reason: 'an empty define must stay empty, not become a fake version',
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
  });

  group('a backlog is paced, not fired all at once', () {
    test('a burst of events cannot become a burst of requests', () async {
      // The 2026-08-17 incident: a till drained its whole queue in back-to-back
      // chunks, taking accepted ingest from 5 to 2,123 requests a minute. For
      // four minutes the shop's own traffic queued behind it — product-list
      // took 104 seconds and the till could not sell.
      var now = DateTime.utc(2026, 8, 17, 11, 38);
      final sink = _FakeAnalyticsSink();
      final engine = AnalyticsEngine(
        sink,
        storage: MemoryAnalyticsQueueStorage(installationId: 'backlog'),
        flushInterval: const Duration(seconds: 120),
        maxBatchSize: 2,
        maxRequestsPerWindow: 3,
        clock: () => now,
      );
      engine.setCurrentUser(1);
      await engine.start();
      sink.submittedBatches.clear();

      // Forty events with the clock held still: every one of these re-triggers
      // a flush, because a queue that cannot drain stays above maxBatchSize.
      await _trackMany(engine, 40);

      expect(
        sink.submittedBatches.length,
        lessThanOrEqualTo(3),
        reason: 'a per-flush cap would hand each of those a fresh budget',
      );
      expect(
        engine.pendingEventCount,
        greaterThan(0),
        reason: 'the rest is kept for the next window, not dropped',
      );
      engine.dispose();
    });

    test('successive windows drain the backlog', () async {
      var now = DateTime.utc(2026, 8, 17, 11, 38);
      final sink = _FakeAnalyticsSink();
      final engine = AnalyticsEngine(
        sink,
        storage: MemoryAnalyticsQueueStorage(installationId: 'drain'),
        flushInterval: const Duration(seconds: 120),
        maxBatchSize: 5,
        maxRequestsPerWindow: 2,
        clock: () => now,
      );
      engine.setCurrentUser(1);
      await engine.start();
      await _trackMany(engine, 30);

      for (var tick = 0; tick < 12; tick += 1) {
        now = now.add(const Duration(seconds: 120));
        await engine.flush();
      }

      expect(
        engine.pendingEventCount,
        0,
        reason: 'pacing must not mean the backlog never ships',
      );
      engine.dispose();
    });

    test('steady traffic never meets the cap', () async {
      // A till at normal volume must be unaffected: the window only bites a
      // backlog.
      var now = DateTime.utc(2026, 8, 17, 11, 38);
      final sink = _FakeAnalyticsSink();
      final engine = AnalyticsEngine(
        sink,
        storage: MemoryAnalyticsQueueStorage(installationId: 'steady'),
        flushInterval: const Duration(seconds: 120),
        maxBatchSize: 100,
        maxRequestsPerWindow: 3,
        clock: () => now,
      );
      engine.setCurrentUser(1);
      await engine.start();

      for (var tick = 0; tick < 5; tick += 1) {
        now = now.add(const Duration(seconds: 120));
        await _trackMany(engine, 4);
        await engine.flush();
      }

      expect(engine.pendingEventCount, 0);
      engine.dispose();
    });

    test('the cap can be lifted', () async {
      final sink = _FakeAnalyticsSink();
      final engine = AnalyticsEngine(
        sink,
        storage: MemoryAnalyticsQueueStorage(installationId: 'uncapped'),
        flushInterval: const Duration(hours: 1),
        maxBatchSize: 2,
        maxRequestsPerWindow: 0,
      );
      engine.setCurrentUser(1);
      await engine.start();
      await _trackMany(engine, 10);

      await engine.flush();

      expect(engine.pendingEventCount, 0);
      engine.dispose();
    });
  });

  group('kiosk devices collect nothing', () {
    test('disabling collection drops the queue and stops recording', () async {
      final sink = _FakeAnalyticsSink(shouldFail: true);
      final storage = MemoryAnalyticsQueueStorage(installationId: 'kiosk');
      final engine = AnalyticsEngine(
        sink,
        storage: storage,
        flushInterval: const Duration(hours: 1),
        maxBatchSize: 2,
      );
      await engine.start();
      await _trackMany(engine, 5);
      expect(engine.pendingEventCount, greaterThan(0));

      await engine.setCollectionEnabled(false);

      expect(engine.pendingEventCount, 0);
      expect(await storage.loadEvents(), isEmpty);

      await _trackMany(engine, 5);
      expect(
        engine.pendingEventCount,
        0,
        reason:
            'a price checker can never sign in, so anything it records is stranded',
      );
      engine.dispose();
    });
  });
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

void _registerBacklogDrainTests() {
  group('a backlogged queue delivers today first', () {
    test('the newest events are sent before the stale ones', () async {
      // The bug this pins: a till that could not deliver for weeks spent its
      // whole send budget shipping the oldest events it held, so the current
      // week never arrived at all. One shop's busiest register was still
      // delivering a single day from three weeks earlier when its export was
      // taken — 38,059 events, none of them recent.
      final sink = _FakeAnalyticsSink(shouldFail: true);
      final storage = MemoryAnalyticsQueueStorage(installationId: 'install-1');
      final engine = AnalyticsEngine(
        sink,
        storage: storage,
        flushInterval: const Duration(hours: 1),
        maxBatchSize: 2,
      );
      engine.setCurrentUser(1);

      for (var i = 0; i < 5; i += 1) {
        await engine.trackUsage(
          AnalyticsEventName.posCheckoutCompleted,
          metrics: {'total': i.toDouble()},
        );
      }
      sink.submittedBatches.clear();

      sink.shouldFail = false;
      await engine.flush();

      expect(sink.submittedBatches, isNotEmpty);
      final firstBatch = sink.submittedBatches.first;
      expect(firstBatch, hasLength(2));
      // The last two recorded, not the first two.
      expect(
        firstBatch.map((event) => event.metrics['total']).toList(),
        [3.0, 4.0],
      );
    });

    test('a restore reads only as deep as the queue is allowed to be', () async {
      final storage = MemoryAnalyticsQueueStorage(installationId: 'install-1');
      // Twelve on disk against a cap of four: the restore must take the newest
      // four and the table must be cut to match, rather than carrying eight
      // events that will never be sent and never dropped.
      await storage.appendEvents([
        for (var i = 0; i < 12; i += 1)
          AnalyticsEventDraft.usage(
            AnalyticsEventName.posCheckoutCompleted,
            metrics: {'total': i.toDouble()},
          ),
      ]);

      final sink = _FakeAnalyticsSink(shouldFail: true);
      final engine = AnalyticsEngine(
        sink,
        storage: storage,
        flushInterval: const Duration(hours: 1),
        maxQueueSize: 4,
        maxBatchSize: 2,
      );
      engine.setCurrentUser(1);
      await engine.flush();

      // Four restored, plus the app.started this engine records on boot.
      expect(engine.pendingEventCount, lessThanOrEqualTo(5));
      expect(await storage.loadEvents(), hasLength(lessThanOrEqualTo(5)));
    });
  });
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
