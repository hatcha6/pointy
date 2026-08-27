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
  testWidgets('interaction tracker records pointer taps', (tester) async {
    final sink = _FakeAnalyticsSink();
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'install-tap'),
      flushInterval: const Duration(hours: 1),
    );
    await engine.start();
    engine.setCurrentUser(1); // authenticated: flush is allowed to POST
    engine.setCurrentScreen('pos');

    await tester.pumpWidget(
      MaterialApp(
        home: AnalyticsInteractionTracker(
          analyticsEngine: engine,
          child: Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {},
                child: const Text('اختبار'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await engine.flush();

    final interactions = _interactionEvents(sink);
    expect(
      interactions.map((event) => event.attributes['action']),
      containsAll(['pointer_down', 'pointer_up']),
    );
    expect(interactions.last.attributes['screen'], 'pos');
    expect(interactions.last.attributes['target'], 'pointer');
    expect(interactions.last.metrics['viewport_width'], isA<num>());
    expect(interactions.last.metrics['x'], isA<num>());
    engine.dispose();
  });

  testWidgets('interaction tracker records scroll and keyboard interactions', (
    tester,
  ) async {
    final sink = _FakeAnalyticsSink();
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'install-input'),
      flushInterval: const Duration(hours: 1),
    );
    await engine.start();
    engine.setCurrentUser(1); // authenticated: flush is allowed to POST
    engine.setCurrentScreen('catalog');

    await tester.pumpWidget(
      MaterialApp(
        home: AnalyticsInteractionTracker(
          analyticsEngine: engine,
          scrollUpdateSampleInterval: Duration.zero,
          child: Scaffold(
            body: Column(
              children: [
                const TextField(),
                Expanded(
                  child: ListView.builder(
                    itemCount: 40,
                    itemBuilder: (context, index) =>
                        ListTile(title: Text('بند $index')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.drag(find.byType(ListView), const Offset(0, -320));
    await tester.pump();
    await engine.flush();

    final actions = _interactionEvents(
      sink,
    ).map((event) => event.attributes['action']).toSet();
    expect(actions, contains('focus_changed'));
    expect(actions, contains('keys_entered'));
    expect(
      actions,
      isNot(contains('key_down')),
      reason: 'individual keystrokes were 1.46M rows and said nothing extra',
    );
    expect(actions, contains('scroll_start'));
    expect(actions, contains('scroll_update'));
    expect(actions, contains('scroll_end'));

    final keyEvent = _interactionEvents(
      sink,
    ).lastWhere((event) => event.attributes['action'] == 'keys_entered');
    // Enter is a commit key, so it closes the run rather than pausing it — the
    // run boundary is the real one instead of whatever an idle timer guessed.
    expect(keyEvent.attributes['last_key_category'], 'submit');
    expect(keyEvent.attributes['last_key'], 'Enter');
    expect(keyEvent.attributes['screen'], 'catalog');
    expect(keyEvent.metrics['key_count'], 1);
    engine.dispose();
  });

  testWidgets('a typed run collapses into one event', (tester) async {
    // A barcode scanner types a whole code in milliseconds; a cashier types a
    // search. Either way the run is the unit that matters, not the keystroke.
    final sink = _FakeAnalyticsSink();
    final engine = AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: 'keys'),
      flushInterval: const Duration(hours: 1),
    );
    engine.setCurrentUser(1);

    await tester.pumpWidget(
      MaterialApp(
        home: AnalyticsInteractionTracker(
          analyticsEngine: engine,
          child: const Scaffold(body: TextField()),
        ),
      ),
    );
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
    await tester.pump();
    await engine.flush();

    final runs = _interactionEvents(sink)
        .where((event) => event.attributes['action'] == 'keys_entered')
        .toList(growable: false);

    expect(runs, hasLength(1), reason: 'five keys, one event');
    expect(runs.single.metrics['key_count'], 5);
    expect(runs.single.metrics['printable_count'], 4);
    // Printable keys are redacted to a placeholder — the tracker never records
    // what was actually typed, and coalescing must not become a way around
    // that. Only the non-printable keys carry a real label.
    expect(runs.single.attributes['first_key'], 'printable_character');
    expect(runs.single.attributes['last_key'], 'Enter');
    engine.dispose();
  });
}

List<AnalyticsEventDraft> _interactionEvents(_FakeAnalyticsSink sink) {
  return sink.acceptedEvents
      .where((event) => event.name == 'frontend.interaction')
      .toList(growable: false);
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
