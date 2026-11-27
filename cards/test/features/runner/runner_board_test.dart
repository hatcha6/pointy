import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/api/relay_api.dart';
import 'package:pointy_cards/src/data/session/session_store.dart';
import 'package:pointy_cards/src/features/runner/runner_board.dart';
import 'package:pointy_cards/src/features/runner/runner_records.dart';
import 'package:pointy_cards/src/features/runner/runner_scores_sheet.dart';

RelayApi apiOn(http.Client client) => RelayApi(
  baseUrl: Uri.parse('https://relay.test'),
  sessions: MemorySessionStore(fixtureSession),
  client: client,
);

void main() {
  testWidgets('the scores sheet opens on this week\'s shared board', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final dependencies = fixtureDependencies();
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: Scaffold(
          body: RunnerScoresSheet(
            records: dependencies.runnerRecords,
            board: dependencies.runnerBoard,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('هذا الأسبوع'), findsOneWidget);
    expect(find.text('الصقر الذهبي'), findsOneWidget);
    // Not in the week's top: the customer's place shows under it.
    expect(find.text('23'), findsOneWidget);
    expect(find.text('أنت'), findsOneWidget);

    await tester.tap(find.text('كل الأوقات'));
    await tester.pumpAndSettle();
    // In the all-time top: marked in place, not repeated below.
    expect(find.text('أنت'), findsOneWidget);
    expect(find.text('23'), findsNothing);

    await tester.tap(find.text('نتائجك'));
    await tester.pumpAndSettle();
    expect(find.text('لا نتائج بعد. أول جولة تبدأ بضغطة.'), findsOneWidget);
  });

  test('a run sent with no connection goes with the next one', () async {
    final sent = <Map<String, dynamic>>[];
    var online = false;
    var refuse = false;
    final api = apiOn(
      MockClient((request) async {
        if (!online) {
          throw http.ClientException('offline');
        }
        sent.add(jsonDecode(request.body) as Map<String, dynamic>);
        return refuse
            ? http.Response('{"code":"implausible_run"}', 422)
            : http.Response('{"best":true}', 200);
      }),
    );
    final board = RunnerBoardRepository(api: api, isSignedIn: () => true);
    RunnerRun run(int score) =>
        RunnerRun(score: score, coins: 0, at: DateTime(2026));

    await board.submit(run(900), const Duration(seconds: 60));
    online = true;
    await board.submit(run(200), const Duration(seconds: 20));
    // The better, unsent run went instead.
    expect(sent.single['score'], 900);
    expect(sent.single['seconds'], 60);

    // A refusal is not tried again.
    refuse = true;
    await board.submit(run(300), const Duration(seconds: 1));
    refuse = false;
    await board.submit(run(100), const Duration(seconds: 10));
    expect(sent.map((s) => s['score']), [900, 300, 100]);
  });
}
