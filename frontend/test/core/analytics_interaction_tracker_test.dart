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
    expect(actions, contains('key_down'));
    expect(actions, contains('scroll_start'));
    expect(actions, contains('scroll_update'));
    expect(actions, contains('scroll_end'));

    final keyEvent = _interactionEvents(
      sink,
    ).lastWhere((event) => event.attributes['action'] == 'key_down');
    expect(keyEvent.attributes['key_category'], 'submit');
    expect(keyEvent.attributes['key_label'], 'Enter');
    expect(keyEvent.attributes['screen'], 'catalog');
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
