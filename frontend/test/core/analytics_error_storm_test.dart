import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/analytics_engine.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/analytics_event.dart';
import 'package:pointy_frontend/src/data/repositories/analytics_repository.dart';
import 'package:pointy_frontend/src/data/services/analytics_queue_storage.dart';

/// One client loop produced 1,999 identical errors in 118 seconds — 92% of
/// every platform error in the dump — and buried everything else.
void main() {
  group('a non-finite metric cannot poison the queue', () {
    test('Infinity is dropped rather than thrown on', () {
      // A division by zero away. jsonEncode throws on Infinity and NaN, and the
      // queue is encoded whole: one poisoned metric made every later write fail,
      // each failure was recorded as an error, and recording it triggered
      // another write.
      final draft = AnalyticsEventDraft.usage(
        AnalyticsEventName.posCheckoutCompleted,
        metrics: {
          'per_base_unit': double.infinity,
          'also_bad': double.nan,
          'negative': double.negativeInfinity,
          'fine': 12.5,
        },
      );

      final metrics = draft.toJson()['metrics']! as Map<String, num>;
      expect(metrics, {'fine': 12.5});
      expect(() => jsonEncodeDraft(draft), returnsNormally);
    });

    test('a non-finite attribute survives as text', () {
      final draft = AnalyticsEventDraft.usage(
        AnalyticsEventName.posCheckoutCompleted,
        attributes: {'ratio': double.infinity, 'name': 'bread'},
      );

      final attributes = draft.toJson()['attributes']! as Map<String, Object?>;
      expect(attributes['ratio'], 'Infinity');
      expect(attributes['name'], 'bread');
      expect(() => jsonEncodeDraft(draft), returnsNormally);
    });

    test('an ordinary event is passed through untouched', () {
      final metrics = {'a': 1, 'b': 2.5};
      final draft = AnalyticsEventDraft.usage(
        AnalyticsEventName.posCheckoutCompleted,
        metrics: metrics,
      );
      expect(draft.toJson()['metrics'], same(metrics));
    });
  });

  group('one repeating error cannot bury the rest', () {
    late _FakeSink sink;
    late DateTime now;
    late AnalyticsEngine engine;

    setUp(() async {
      sink = _FakeSink();
      now = DateTime.utc(2026, 8, 27, 9);
      engine = AnalyticsEngine(
        sink,
        storage: MemoryAnalyticsQueueStorage(installationId: 'install-storm'),
        flushInterval: const Duration(hours: 1),
        maxBatchSize: 500,
        clock: () => now,
        errorRepeatWindow: const Duration(minutes: 1),
      );
      await engine.start();
      engine.setCurrentUser(1);
    });

    tearDown(() => engine.dispose());

    Future<void> raise(String message) =>
        engine.captureError(StateError(message), StackTrace.empty);

    List<AnalyticsEventDraft> errorsIn(List<AnalyticsEventDraft> events) =>
        events.where((e) => e.name == 'app.platform_error').toList();

    test('a storm of one error is recorded once', () async {
      for (var i = 0; i < 500; i += 1) {
        await raise('Converting object to an encodable object failed');
      }
      await engine.flush();

      expect(errorsIn(sink.accepted), hasLength(1));
    });

    test('a different error still gets through the storm', () async {
      for (var i = 0; i < 200; i += 1) {
        await raise('the loop');
      }
      await raise('something else entirely');
      await engine.flush();

      final messages = errorsIn(
        sink.accepted,
      ).map((e) => e.attributes['message']).toList();
      expect(messages, hasLength(2));
      expect(messages.last, contains('something else entirely'));
    });

    test('the suppressed volume is carried, not lost', () async {
      for (var i = 0; i < 50; i += 1) {
        await raise('the loop');
      }
      now = now.add(const Duration(minutes: 2));
      await raise('the loop');
      await engine.flush();

      final errors = errorsIn(sink.accepted);
      expect(errors, hasLength(2));
      expect(errors.last.attributes['suppressed_since_last'], 49);
    });

    test('the window reopens once it expires', () async {
      await raise('the loop');
      await raise('the loop');
      now = now.add(const Duration(minutes: 5));
      await raise('the loop');
      await engine.flush();

      expect(errorsIn(sink.accepted), hasLength(2));
    });
  });
}

/// Encoding the way the queue does it.
String jsonEncodeDraft(AnalyticsEventDraft draft) {
  return const JsonEncoder().convert(draft.toJson());
}

class _FakeSink implements AnalyticsEventSink {
  final List<AnalyticsEventDraft> accepted = [];

  @override
  Future<Result<AnalyticsIngestResult>> ingestEvents(
    List<AnalyticsEventDraft> events,
  ) async {
    accepted.addAll(events);
    return Ok(
      AnalyticsIngestResult(
        accepted: events.length,
        duplicates: 0,
        eventIds: const [],
      ),
    );
  }
}
