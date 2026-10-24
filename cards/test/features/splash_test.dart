import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/features/splash/splash_overlay.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('the full opening plays once, then quick ones for six hours', () async {
    final morning = DateTime(2026, 10, 24, 9);
    expect(await SplashMemory.next(now: morning), SplashRun.full);
    expect(
      await SplashMemory.next(now: morning.add(const Duration(minutes: 5))),
      SplashRun.quick,
    );
    expect(
      await SplashMemory.next(now: morning.add(const Duration(hours: 5))),
      SplashRun.quick,
    );
    expect(
      await SplashMemory.next(now: morning.add(const Duration(hours: 7))),
      SplashRun.full,
    );
  });

  testWidgets('the opening plays, spells the name and leaves the app', (
    tester,
  ) async {
    var done = false;
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: Stack(
          children: [
            const Text('التطبيق'),
            SplashOverlay(run: SplashRun.full, onDone: () => done = true),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(done, isTrue);
    expect(find.text('كروت'), findsOneWidget);
  });

  testWidgets('the app runs under the opening, which removes itself', (
    tester,
  ) async {
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        splash: const SplashOpening(SplashRun.quick),
      ),
    );
    // Under the opening, the app has already built its home.
    expect(find.byType(SplashOverlay), findsOneWidget);
    expect(find.text('اكتشف الكروت', skipOffstage: false), findsOneWidget);
    // A quick opening is over in well under a second.
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.byType(SplashOverlay), findsNothing);
  });

  testWidgets('a tap skips the opening', (tester) async {
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        splash: const SplashOpening(SplashRun.full),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(SplashOverlay));
    // Only the fade out is left: gone in under half a second, where the
    // untouched opening would run for one and a half.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(find.byType(SplashOverlay), findsNothing);
  });
}
