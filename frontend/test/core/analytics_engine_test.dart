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

  test('analytics engine records API request performance', () async {
    final sink = _FakeAnalyticsSink();
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'install-3'),
      flushInterval: const Duration(hours: 1),
    );
    await engine.start();

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
