import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/analytics_engine.dart';
import 'package:pointy_frontend/src/core/analytics_interaction_tracker.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/analytics_event.dart';
import 'package:pointy_frontend/src/data/repositories/analytics_repository.dart';
import 'package:pointy_frontend/src/data/services/analytics_queue_storage.dart';

void main() {
  late _FakeAnalyticsSink sink;
  late AnalyticsEngine engine;
  late _TestClock clock;

  setUp(() {
    sink = _FakeAnalyticsSink();
    clock = _TestClock();
    engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'install-ui'),
      flushInterval: const Duration(hours: 1),
    )..setCurrentUser(1); // authenticated: flush is allowed to POST
  });

  Future<void> pumpTracker(WidgetTester tester, Widget body) {
    return tester.pumpWidget(
      MaterialApp(
        home: AnalyticsInteractionTracker(
          analyticsEngine: engine,
          clock: clock.now,
          child: Scaffold(body: body),
        ),
      ),
    );
  }

  /// Tears the tracker down, which settles every open run, then delivers.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await engine.flush();
    engine.dispose();
  }

  List<AnalyticsEventDraft> interactions() {
    return sink.acceptedEvents
        .where((event) => event.name == 'frontend.interaction')
        .toList(growable: false);
  }

  Set<Object?> actions() {
    return interactions()
        .map((event) => event.attributes['action'])
        .toSet();
  }

  AnalyticsEventDraft only(String action) {
    final matching = interactions()
        .where((event) => event.attributes['action'] == action)
        .toList(growable: false);
    expect(matching, hasLength(1), reason: 'expected exactly one $action');
    return matching.single;
  }

  group('raw pointing leaves as a run, not a row per press', () {
    testWidgets('three taps are one event', (tester) async {
      // Pointer downs and ups were 28,531 rows in one field week, and a
      // `pointer_down` at (154, 130) is not a finding on its own.
      await engine.start();
      engine.setCurrentScreen('pos');
      await pumpTracker(
        tester,
        Center(child: FilledButton(onPressed: () {}, child: const Text('ادفع'))),
      );

      for (var tap = 0; tap < 3; tap += 1) {
        await tester.tap(find.byType(FilledButton));
        clock.advance(const Duration(milliseconds: 200));
        await tester.pump();
      }
      await settle(tester);

      expect(actions(), isNot(contains('pointer_down')));
      expect(actions(), isNot(contains('pointer_up')));
      final run = only('input_activity');
      expect(run.metrics['press_count'], 3);
      expect(run.metrics['release_count'], 3);
      expect(run.attributes['screen'], 'pos');
      expect(run.metrics['viewport_width'], isA<num>());
    });

    testWidgets('tapping the same spot again is counted as a repeat', (
      tester,
    ) async {
      // The finding the raw stream could not produce. 21.7% of field taps
      // landed within 24px and 1.2s of the previous one, in 558 runs of three
      // or more — a control that did nothing the first time.
      await engine.start();
      engine.setCurrentScreen('pos');
      await pumpTracker(
        tester,
        Center(child: FilledButton(onPressed: () {}, child: const Text('ادفع'))),
      );

      for (var tap = 0; tap < 3; tap += 1) {
        await tester.tap(find.byType(FilledButton));
        clock.advance(const Duration(milliseconds: 150));
        await tester.pump();
      }
      await settle(tester);

      final run = only('input_activity');
      expect(run.metrics['repeat_press_count'], 2);
      expect(run.metrics['max_repeat_run'], 3);
    });

    testWidgets('a tap after a long pause is not a repeat', (tester) async {
      await engine.start();
      engine.setCurrentScreen('pos');
      await pumpTracker(
        tester,
        Center(child: FilledButton(onPressed: () {}, child: const Text('ادفع'))),
      );

      await tester.tap(find.byType(FilledButton));
      clock.advance(const Duration(seconds: 3));
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      await settle(tester);

      final run = only('input_activity');
      expect(run.metrics['press_count'], 2);
      expect(
        run.metrics['repeat_press_count'],
        0,
        reason: 'a cashier coming back to a button is not rage-tapping it',
      );
    });

    testWidgets('where the taps landed survives as a histogram', (
      tester,
    ) async {
      await engine.start();
      await pumpTracker(
        tester,
        Center(child: FilledButton(onPressed: () {}, child: const Text('ادفع'))),
      );

      await tester.tap(find.byType(FilledButton));
      await settle(tester);

      final run = only('input_activity');
      final grid = run.attributes['press_grid'] as List<Object?>;
      expect(grid, hasLength(12));
      expect(
        grid.whereType<int>().reduce((a, b) => a + b),
        1,
        reason: 'enough to draw a heat map, not to replay a gesture',
      );
    });
  });

  group('one flick is one scroll', () {
    testWidgets('a drag collapses into a single gesture', (tester) async {
      // A start, a direction, several updates and an end: five rows for one
      // movement of one thumb, and the thing anyone wants to know — how far
      // did they scroll, did they hit the end — was joinable from none of them.
      await engine.start();
      engine.setCurrentScreen('catalog');
      await pumpTracker(
        tester,
        ListView.builder(
          itemCount: 60,
          itemBuilder: (context, index) => ListTile(title: Text('بند $index')),
        ),
      );

      await tester.drag(find.byType(ListView), const Offset(0, -320));
      await tester.pumpAndSettle();
      await settle(tester);

      expect(actions(), isNot(contains('scroll_start')));
      expect(actions(), isNot(contains('scroll_update')));
      expect(actions(), isNot(contains('scroll_end')));

      final scroll = only('scrolled');
      expect(scroll.attributes['axis'], 'vertical');
      expect(scroll.attributes['screen'], 'catalog');
      expect(scroll.attributes['completed'], isTrue);
      expect(scroll.attributes['direction'], 'forward');
      expect(scroll.metrics['update_count'], greaterThan(1));
      expect(scroll.metrics['distance'], greaterThan(0));
      expect(scroll.metrics['net_delta'], greaterThan(0));
      expect(scroll.metrics['sample_count'], greaterThan(1));
    });

    testWidgets('distance counts every update, never a sample of them', (
      tester,
    ) async {
      // The old sampler dropped scroll updates on a 250ms throttle. Summing a
      // throttled stream would leave the distance short by exactly what it
      // dropped, so the sampler had to go when distance became the point.
      await engine.start();
      await pumpTracker(
        tester,
        ListView.builder(
          itemCount: 200,
          itemBuilder: (context, index) => ListTile(title: Text('بند $index')),
        ),
      );

      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();
      await settle(tester);

      final scroll = only('scrolled');
      expect((scroll.metrics['distance'] as num) >= 500, isTrue);
    });

    testWidgets('running the list out is recorded', (tester) async {
      // A cashier who reaches the bottom of a catalog did not find what they
      // wanted where they expected it.
      await engine.start();
      await pumpTracker(
        tester,
        ListView.builder(
          itemCount: 20,
          itemBuilder: (context, index) => ListTile(title: Text('بند $index')),
        ),
      );

      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      await settle(tester);

      expect(only('scrolled').attributes['reached_end'], isTrue);
    });
  });

  group('focus churn is counted, not narrated', () {
    testWidgets('a focus change adds to the run instead of its own row', (
      tester,
    ) async {
      // 12,200 focus rows in a field week, of which 12,170 named `FocusScope`,
      // `Focus`, or an obfuscated private symbol — never the field. Only 30
      // recorded a loss, so there was not even a dwell time to be had.
      await engine.start();
      engine.setCurrentScreen('login');
      await pumpTracker(tester, const TextField());

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await settle(tester);

      expect(actions(), isNot(contains('focus_changed')));
      expect(
        only('input_activity').metrics['focus_change_count'],
        greaterThan(0),
      );
    });
  });

  group('typing still collapses into a run', () {
    testWidgets('five keys, one event, and nothing typed is recorded', (
      tester,
    ) async {
      await engine.start();
      engine.setCurrentScreen('catalog');
      await pumpTracker(tester, const TextField());

      await tester.tap(find.byType(TextField));
      await tester.pump();
      for (final key in const [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);

      final run = only('keys_entered');
      expect(run.metrics['key_count'], 5);
      expect(run.metrics['printable_count'], 4);
      expect(run.attributes['screen'], 'catalog');
      // Printable keys are redacted to a placeholder; coalescing must never
      // become a way around that.
      expect(run.attributes['first_key'], 'printable_character');
      expect(run.attributes['last_key'], 'Enter');
      expect(actions(), isNot(contains('key_down')));
    });
  });
}

class _TestClock {
  DateTime _now = DateTime.utc(2026, 9, 16, 8);

  DateTime now() => _now;

  void advance(Duration by) => _now = _now.add(by);
}

class _FakeAnalyticsSink implements AnalyticsEventSink {
  final List<AnalyticsEventDraft> acceptedEvents = [];

  @override
  Future<Result<AnalyticsIngestResult>> ingestEvents(
    List<AnalyticsEventDraft> events,
  ) async {
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
