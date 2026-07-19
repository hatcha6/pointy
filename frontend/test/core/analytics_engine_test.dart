import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/analytics_engine.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/analytics_event.dart';
import 'package:pointy_frontend/src/data/repositories/analytics_repository.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/analytics_queue_storage.dart';

void main() {
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
      expect((await storage.loadEvents()).length, 2);
      expect(sink.submittedBatches, hasLength(2));

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
