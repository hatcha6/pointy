import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/features/orders/order_progress_page.dart';
import 'package:pointy_cards/src/features/orders/order_watcher.dart';
import 'package:pointy_cards/src/features/reveal/reveal_page.dart';
import 'package:pointy_cards/src/features/runner/runner_game.dart';
import 'package:pointy_cards/src/features/runner/runner_overlays.dart';
import 'package:pointy_cards/src/features/runner/runner_painter.dart';
import 'package:pointy_cards/src/features/runner/runner_records.dart';
import 'package:pointy_cards/src/features/runner/runner_sprites.dart';
import 'package:pointy_cards/src/features/runner/runner_world.dart';

/// The relay, with the order still on its way until [delivered].
class _LateOrder extends http.BaseClient {
  final _waiting = fixtureRelay(orderStatus: 'fulfilling');
  final _arrived = fixtureRelay();
  bool delivered = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      (delivered ? _arrived : _waiting).send(request);
}

Future<void> _phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  // Decoding pictures is real work, outside the test's fake clock.
  await tester.runAsync(RunnerSprites.load);
}

void main() {
  testWidgets('a run is counted in the records when it ends', (tester) async {
    await _phone(tester);
    final dependencies = fixtureDependencies();
    final records = dependencies.runnerRecords;
    final game = GlobalKey<RunnerGameState>();
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: Scaffold(
          body: Center(
            child: RunnerGame(
              key: game,
              records: records,
              audio: dependencies.runnerAudio,
              seed: 1,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RunnerLoading), findsNothing);
    expect(find.text('اضغط للقفز'), findsOneWidget);

    await tester.tap(find.byType(RunnerGame));
    await tester.pump(const Duration(milliseconds: 100));
    expect(game.currentState!.inRun, isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('اضغط للقفز'), findsNothing);

    // Nobody jumps again: the first obstacle ends it.
    for (var i = 0; i < 60 * 8 && game.currentState!.inRun; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(game.currentState!.world.phase, RunnerPhase.over);
    expect(find.text('انتهت الجولة'), findsOneWidget);
    expect(records.played, 1);
    expect(records.best, game.currentState!.world.score);
    expect(records.best, greaterThan(0));

    // A tap right after the crash does not throw the score away...
    await tester.tap(find.byType(RunnerGame));
    await tester.pump();
    expect(game.currentState!.world.phase, RunnerPhase.over);
    // ...a moment later it starts the next run.
    // (The game never steps more than a tenth of a second a frame.)
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.tap(find.byType(RunnerGame));
    await tester.pump(const Duration(milliseconds: 50));
    expect(game.currentState!.world.phase, RunnerPhase.running);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the entrance plays frame by frame, then the hint shows', (
    tester,
  ) async {
    await _phone(tester);
    final dependencies = fixtureDependencies();
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: Scaffold(
          body: Center(
            child: RunnerGame(
              records: dependencies.runnerRecords,
              audio: dependencies.runnerAudio,
              reveal: true,
              seed: 1,
            ),
          ),
        ),
      ),
    );
    // The painter is only repainted, never rebuilt, while the entrance
    // plays: it must read a clock that moves.
    RunnerPainter painter() =>
        tester
                .widget<CustomPaint>(
                  find
                      .descendant(
                        of: find.byType(RunnerGame),
                        matching: find.byType(CustomPaint),
                      )
                      .first,
                )
                .painter!
            as RunnerPainter;
    final first = painter();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(painter().introClock!.value, greaterThan(0.3));
    expect(identical(painter().introClock, first.introClock), isTrue);
    expect(find.text('اضغط للقفز'), findsNothing);
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(painter().introClock!.value, isNull);
    expect(find.text('اضغط للقفز'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the records keep the best runs, best first', (tester) async {
    final records = RunnerRecords();
    for (final score in [40, 900, 120, 0, 350]) {
      records.add(RunnerRun(score: score, coins: 1, at: DateTime(2026)));
    }
    expect(records.top.map((r) => r.score), [900, 350, 120, 40]);
    expect(records.played, 5);
    expect(records.coins, 5);
    expect(records.unlocked(RunnerCharacter.pink), isTrue);
    expect(records.unlocked(RunnerCharacter.purple), isFalse);
    // A locked runner cannot be chosen.
    records.character = RunnerCharacter.yellow;
    expect(records.character, RunnerCharacter.green);
    records.character = RunnerCharacter.pink;
    expect(records.character, RunnerCharacter.pink);
    expect(records.unlockedBy(100, 900), [
      RunnerCharacter.beige,
      RunnerCharacter.pink,
    ]);
  });

  group('the waiting page', () {
    // The watcher's clock must stop before the test ends.
    Future<void> close(WidgetTester tester, OrderWatcher watcher) async {
      await tester.pumpWidget(const SizedBox());
      watcher.dispose();
    }

    Future<(OrderWatcher, _LateOrder)> open(
      WidgetTester tester, {
      required Duration paidAgo,
    }) async {
      await _phone(tester);
      final relay = _LateOrder();
      final dependencies = fixtureDependencies(client: relay);
      final watcher = OrderWatcher(
        orders: dependencies.orders,
        vault: dependencies.vault,
        order: CardOrder.fromJson(
          fixtureOrder(status: 'fulfilling')
            ..['paid_at'] = DateTime.now().subtract(paidAgo).toIso8601String(),
        ),
      )..start();
      await tester.pumpWidget(
        CardsApp(
          dependencies: dependencies,
          home: OrderProgressPage(watcher: watcher, openPaymentPage: false),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      return (watcher, relay);
    }

    testWidgets('offers the game once the wait runs long', (tester) async {
      final (watcher, _) = await open(tester, paidAgo: Duration.zero);
      expect(find.byType(RunnerGame), findsNothing);
      await tester.pump(OrderProgressPage.playAfter);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(RunnerGame), findsOneWidget);
      expect(find.text('يأخذ وقتاً أطول من المعتاد'), findsOneWidget);
      await close(tester, watcher);
    });

    testWidgets('an order that lands mid-run waits for the player', (
      tester,
    ) async {
      final (watcher, relay) = await open(
        tester,
        paidAgo: const Duration(seconds: 30),
      );
      expect(find.byType(RunnerGame), findsOneWidget);
      expect(find.byType(RunnerLoading), findsNothing);
      // The entrance plays first; then a tap starts the run.
      for (var i = 0; i < 130; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.tap(find.byType(RunnerGame));
      relay.delivered = true;
      // The watcher asks again within two seconds; the run is still on.
      for (var i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(RevealPage), findsNothing);
      expect(find.text('اعرضه الآن'), findsOneWidget);

      await tester.tap(find.text('اعرضه الآن'));
      await tester.pumpAndSettle();
      expect(find.byType(RevealPage), findsOneWidget);
      await close(tester, watcher);
    });

    testWidgets('an order that lands between runs opens at once', (
      tester,
    ) async {
      final (watcher, relay) = await open(
        tester,
        paidAgo: const Duration(seconds: 30),
      );
      relay.delivered = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byType(RevealPage), findsOneWidget);
      await close(tester, watcher);
    });
  });
}
