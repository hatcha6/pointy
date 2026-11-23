import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/shared/container_route.dart';
import 'package:pointy_cards/src/shared/micro.dart';

Future<void> _backGesture(
  WidgetTester tester,
  String method, [
  double? progress,
]) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
  'flutter/backgesture',
  const StandardMethodCodec().encodeMethodCall(
    MethodCall(
      method,
      progress == null
          ? null
          : <String, dynamic>{
              'touchOffset': <double>[5.0, 400.0],
              'progress': progress,
              'swipeEdge': 0,
            },
    ),
  ),
  (_) {},
);

const _page = Key('page');

/// A tile that opens a page out of itself.
Widget _app() => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomLeft,
      child: Builder(
        builder: (tile) => GestureDetector(
          onTap: () => openContainer<void>(
            tile,
            from: tile,
            builder: (_) => const Scaffold(
              key: _page,
              body: Center(child: Text('opened')),
            ),
          ),
          child: const SizedBox(
            width: 120,
            height: 80,
            child: ColoredBox(color: Colors.teal, child: Text('tile')),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.pumpWidget(_app());
  await tester.tap(find.text('tile'));
  await tester.pumpAndSettle();
  expect(tester.getSize(find.byKey(_page)), const Size(800, 600));
}

/// The page as it shows: smaller than the screen while it is on its way.
double _width(WidgetTester tester) =>
    tester.getRect(find.byKey(ContainerPageRoute.boxKey)).width;

void main() {
  testWidgets('a page grows out of what was tapped, and a back button sends '
      'it back there', (tester) async {
    await tester.pumpWidget(_app());
    final tile = tester.getRect(find.text('tile'));
    await tester.tap(find.text('tile'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    // Just open: still about the tile, where the tile is.
    final early = tester.getRect(find.byKey(ContainerPageRoute.boxKey));
    expect(early.width, lessThan(400));
    expect(early.center.dy, greaterThan(300));
    expect((early.left - tile.left).abs(), lessThan(40));
    await tester.pumpAndSettle();
    expect(_width(tester), 800);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(_width(tester), lessThan(600));
    await tester.pumpAndSettle();
    expect(find.text('opened'), findsNothing);
  });

  testWidgets('the iOS edge swipe shrinks it under the finger, and letting '
      'go sends it back', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _open(tester);
      final gesture = await tester.startGesture(const Offset(2, 300));
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      final quarter = _width(tester);
      expect(quarter, lessThan(800));
      await gesture.moveBy(const Offset(280, 0));
      await tester.pump();
      // Further across, smaller still: the finger is what moves it.
      expect(_width(tester), lessThan(quarter));
      expect(find.text('tile'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('opened'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('an iOS swipe let go early grows it back', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _open(tester);
      final gesture = await tester.startGesture(const Offset(2, 300));
      await gesture.moveBy(const Offset(120, 0));
      await tester.pump();
      expect(_width(tester), lessThan(800));
      // Held still, then let go: not far enough to leave.
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('opened'), findsOneWidget);
      expect(_width(tester), 800);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets("Android's predictive back shrinks it as the finger moves; "
      'calling it off grows it back, letting go sends it back', (tester) async {
    await _open(tester);
    await _backGesture(tester, 'startBackGesture', 0);
    await _backGesture(tester, 'updateBackGestureProgress', 0.5);
    await tester.pump();
    final half = _width(tester);
    expect(half, lessThan(800));
    await _backGesture(tester, 'updateBackGestureProgress', 1);
    await tester.pump();
    expect(_width(tester), lessThan(half));

    await _backGesture(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();
    expect(_width(tester), 800);

    await _backGesture(tester, 'startBackGesture', 0);
    await _backGesture(tester, 'updateBackGestureProgress', 0.6);
    await tester.pump();
    await _backGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('opened'), findsNothing);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(navigator.userGestureInProgress, isFalse);
  });

  group('costs little per frame', () {
    var builds = 0;
    var moved = 0;

    Widget app() => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: Builder(
            builder: (tile) => GestureDetector(
              onTap: () => openContainer<void>(
                tile,
                from: tile,
                builder: (_) =>
                    _Counted(onBuild: () => builds++, onMove: () => moved++),
              ),
              child: const ContainerSource(
                child: SizedBox(
                  width: 120,
                  height: 80,
                  child: ColoredBox(color: Colors.teal, child: Text('tile')),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    /// Every layer on screen that draws through an offscreen pass.
    List<Layer> offscreen(WidgetTester tester) => [
      for (final layer in tester.layers)
        // (An opacity layer at full strength is passed straight through.)
        if ((layer is OpacityLayer && layer.alpha != 255) ||
            layer is ShaderMaskLayer ||
            layer is BackdropFilterLayer ||
            layer is ImageFilterLayer)
          layer,
    ];

    setUp(() => builds = moved = 0);

    testWidgets('the page is built once and never changes place, through a '
        'push, a gesture called off, and a gesture that leaves', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.tap(find.text('tile'));
      await tester.pump();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(builds, 1);

      await _backGesture(tester, 'startBackGesture', 0);
      for (var i = 1; i <= 10; i++) {
        await _backGesture(tester, 'updateBackGestureProgress', i / 10);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await _backGesture(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      await _backGesture(tester, 'startBackGesture', 0);
      await _backGesture(tester, 'updateBackGestureProgress', 0.5);
      await tester.pump();
      await _backGesture(tester, 'commitBackGesture');
      await tester.pump(const Duration(milliseconds: 60));
      // Still on its way out: built once, and never taken out of the tree
      // and put back, which would lay the whole page out again.
      expect(find.text('opened'), findsOneWidget);
      expect(builds, 1);
      expect(moved, 0);
      await tester.pumpAndSettle();
      expect(find.text('opened'), findsNothing);
    });

    testWidgets('the page never fades through an offscreen layer: only the '
        'small source does, while the page is not painted', (tester) async {
      await tester.pumpWidget(app());
      bool pagePainted() =>
          find.byKey(_page).evaluate().isNotEmpty &&
          tester
                  .widget<Opacity>(
                    find
                        .ancestor(
                          of: find.byKey(_page),
                          matching: find.byType(Opacity),
                        )
                        .first,
                  )
                  .opacity >
              0;
      await tester.tap(find.text('tile'));
      await tester.pump();
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (pagePainted()) {
          expect(offscreen(tester), isEmpty, reason: 'frame $i of the push');
        }
      }
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pump();
      for (var i = 0; i < 18; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (pagePainted()) {
          expect(offscreen(tester), isEmpty, reason: 'frame $i of the pop');
        }
      }
      await tester.pumpAndSettle();
    });

    testWidgets('starts as the tapped widget itself, which enlarges: the '
        'first frame draws it again at its own place and size, its own place '
        'stands empty meanwhile, and no frame of the landing has neither', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      final tile = tester.getRect(find.text('tile'));
      bool shown() => tester
          .widget<Visibility>(
            find.descendant(
              of: find.byType(ContainerSource, skipOffstage: false),
              matching: find.byType(Visibility, skipOffstage: false),
            ),
          )
          .visible;
      // The source drawn again inside the container.
      final again = find.descendant(
        of: find.byType(FittedBox),
        matching: find.text('tile'),
      );
      await tester.tap(find.text('tile'));
      // A pushed page's first frame is built unseen: the tile is still there.
      await tester.pump();
      expect(shown(), isTrue);
      await tester.pump();
      expect(again, findsOneWidget);
      expect(tester.getRect(again), tile);
      await tester.pump(const Duration(milliseconds: 16));
      expect(shown(), isFalse);
      // It enlarges with the container.
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getRect(again).width, greaterThan(tile.width));
      await tester.pumpAndSettle();
      expect(again, findsNothing);
      expect(shown(), isFalse);

      await tester.binding.handlePopRoute();
      await tester.pump();
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        // Once the container is back near the tile's size, or gone.
        final page = find.byKey(_page).evaluate();
        if (page.isEmpty ||
            tester.getRect(find.byKey(ContainerPageRoute.boxKey)).width <
                tile.width * 1.5) {
          expect(
            shown() || again.evaluate().isNotEmpty,
            isTrue,
            reason: 'frame $i of the landing',
          );
        }
      }
      expect(shown(), isTrue);
      expect(again, findsNothing);
    });

    testWidgets('the page is never seen squeezed into the tile: it is not '
        'painted while the container is near the tile\'s size, opening or '
        'closing, by button or by finger', (tester) async {
      await tester.pumpWidget(app());
      final tile = tester.getRect(find.text('tile'));
      // Whether the page is painted, and how wide its container is.
      bool painted() =>
          tester
              .widget<Opacity>(
                find
                    .ancestor(
                      of: find.byKey(_page),
                      matching: find.byType(Opacity),
                    )
                    .first,
              )
              .opacity >
          0;
      double width() =>
          tester.getRect(find.byKey(ContainerPageRoute.boxKey)).width;
      void check(String when) {
        if (width() < tile.width * 2) {
          expect(painted(), isFalse, reason: '$when, at ${width()} wide');
        }
      }

      await tester.tap(find.text('tile'));
      await tester.pump();
      await tester.pump();
      // Its first frame: the tile's own box.
      expect(
        tester.getRect(find.byKey(ContainerPageRoute.boxKey)).topLeft,
        tile.topLeft,
      );
      expect(width(), moreOrLessEquals(tile.width, epsilon: 1));
      var seen = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        check('opening, frame $i');
        seen = seen || painted();
      }
      await tester.pumpAndSettle();
      expect(seen, isTrue);
      expect(painted(), isTrue);

      await tester.binding.handlePopRoute();
      await tester.pump();
      for (var i = 0; i < 30 && find.byKey(_page).evaluate().isNotEmpty; i++) {
        check('closing, frame $i');
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();

      // By finger: Android's back swipe, let go.
      await tester.tap(find.text('tile'));
      await tester.pumpAndSettle();
      await _backGesture(tester, 'startBackGesture', 0);
      await _backGesture(tester, 'updateBackGestureProgress', 1);
      await tester.pump();
      await _backGesture(tester, 'commitBackGesture');
      for (var i = 0; i < 30 && find.byKey(_page).evaluate().isNotEmpty; i++) {
        check('swiped back, frame $i');
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(_page), findsNothing);
    });
  });

  testWidgets('a page opens out of the tile that was tapped, not the first '
      'one in its list', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            itemCount: 3,
            // As a shelf does it: each tile under a context of its own.
            itemBuilder: (_, index) => Builder(
              builder: (tile) => GestureDetector(
                onTap: () => openContainer<void>(
                  tile,
                  from: tile,
                  builder: (_) => const Scaffold(key: _page),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: ContainerSource(
                    child: SizedBox(height: 80, child: Text('tile $index')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final second = tester.getRect(find.text('tile 1'));
    await tester.tap(find.text('tile 1'));
    await tester.pump();
    await tester.pump();
    expect(
      tester.getRect(find.byKey(ContainerPageRoute.boxKey)).topLeft,
      second.topLeft,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('a page whose source left the tree while it was up still goes '
      'back (a null check threw from the gone source)', (tester) async {
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: shown,
            builder: (_, shown, _) => Column(
              children: [
                if (shown)
                  Builder(
                    builder: (tile) => GestureDetector(
                      onTap: () => openContainer<void>(
                        tile,
                        from: tile,
                        builder: (_) => const Scaffold(key: _page),
                      ),
                      child: const ContainerSource(
                        child: SizedBox(height: 80, child: Text('tile')),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('tile'));
    await tester.pumpAndSettle();
    shown.value = false;
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(_page), findsNothing);
  });

  testWidgets('a context shared by several tiles is refused, never guessed '
      'from', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (shared) => Column(
            children: [
              for (final name in ['a', 'b'])
                GestureDetector(
                  onTap: () => ContainerSource.find(shared),
                  child: ContainerSource(child: Text(name)),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('b'));
    expect(tester.takeException(), isAssertionError);
  });

  testWidgets('the source glides onto its landing in the page, and the page '
      'is never painted in the same frame as the source (the iPhone drew the '
      'page over it on the way back)', (tester) async {
    const landing = Key('landing');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: Builder(
              builder: (tile) => GestureDetector(
                onTap: () => openContainer<void>(
                  tile,
                  from: tile,
                  builder: (_) => const Scaffold(
                    key: _page,
                    body: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: EdgeInsets.only(top: 100),
                        child: ContainerLanding(
                          child: SizedBox(
                            key: landing,
                            width: 300,
                            height: 200,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const ContainerSource(
                  child: SizedBox(width: 120, height: 80, child: Text('tile')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final again = find.descendant(
      of: find.byType(FittedBox),
      matching: find.text('tile'),
    );
    bool pagePainted() =>
        find.byKey(_page).evaluate().isNotEmpty &&
        tester
                .widget<Opacity>(
                  find
                      .ancestor(
                        of: find.byKey(_page),
                        matching: find.byType(Opacity),
                      )
                      .first,
                )
                .opacity >
            0;
    Rect? last;
    Future<void> frames(String when) async {
      for (var i = 0; i < 40 && find.byKey(_page).evaluate().isNotEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final shown = again.evaluate().isNotEmpty;
        expect(shown && pagePainted(), isFalse, reason: '$when, frame $i');
        if (shown) {
          last = tester.getRect(again);
          // It rides in the container: always inside it, never cut by it.
          final box = tester
              .getRect(find.byKey(ContainerPageRoute.boxKey))
              .inflate(1);
          expect(
            box.contains(last!.topLeft) && box.contains(last!.bottomRight),
            isTrue,
            reason: '$when, frame $i: $last outside $box',
          );
        } else if (pagePainted()) {
          // Once the page's own has taken over, the container holds all of
          // it: it is never cut by the container's edge either.
          final box = tester
              .getRect(find.byKey(ContainerPageRoute.boxKey))
              .inflate(1);
          final own = tester.getRect(find.byKey(landing));
          expect(
            box.contains(own.topLeft) && box.contains(own.bottomRight),
            isTrue,
            reason: '$when, frame $i: landing $own outside $box',
          );
        }
      }
    }

    await tester.tap(find.text('tile'));
    // (A pushed page's first frame is built unseen.)
    await tester.pump();
    await tester.pump();
    await frames('opening');
    await tester.pumpAndSettle();
    // Where the source was last seen is where the page's own then stood.
    expect(pagePainted(), isTrue);
    // Where the source was last seen is where the page's own then stood.
    expect(last, isNotNull);
    final own = tester.getRect(find.byKey(landing));
    expect((last!.center - own.center).distance, lessThan(12));

    await tester.binding.handlePopRoute();
    await tester.pump();
    await frames('closing');
    await tester.pumpAndSettle();
    expect(find.byKey(_page), findsNothing);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('a page opened out of a tile, itself in a page opened out of '
        'a tile, lands back on its tile: the page beneath does not slide '
        'aside under it ($platform)', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomLeft,
                child: Builder(
                  builder: (outer) => GestureDetector(
                    onTap: () => openContainer<void>(
                      outer,
                      from: outer,
                      builder: (_) => Scaffold(
                        body: Align(
                          alignment: Alignment.centerRight,
                          child: Builder(
                            builder: (inner) => GestureDetector(
                              onTap: () => openContainer<void>(
                                inner,
                                from: inner,
                                builder: (_) => const Scaffold(key: _page),
                              ),
                              child: const SizedBox(
                                width: 100,
                                height: 60,
                                child: Text('inner'),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    child: const SizedBox(
                      width: 120,
                      height: 80,
                      child: Text('outer'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('outer'));
        await tester.pumpAndSettle();
        final tile = tester.getRect(find.text('inner'));
        await tester.tap(find.text('inner'));
        await tester.pump();
        // Opening, and open: the page beneath stays where it was.
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            tester.getRect(find.text('inner', skipOffstage: false)),
            tile,
            reason: 'opening, frame $i',
          );
        }
        await tester.pumpAndSettle();
        expect(tester.getRect(find.text('inner', skipOffstage: false)), tile);

        // Going back, the container closes onto the tile itself.
        await tester.binding.handlePopRoute();
        await tester.pump();
        Rect? last;
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          final box = find.byKey(ContainerPageRoute.boxKey);
          if (find.byKey(_page).evaluate().isEmpty) {
            break;
          }
          last = tester.getRect(box.last);
        }
        await tester.pumpAndSettle();
        expect(last, isNotNull);
        expect((last!.topLeft - tile.topLeft).distance, lessThan(8));
        expect(tester.getRect(find.text('inner')), tile);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets("a row's picture goes to the landing from its own place in "
      'the row, while the page opens out of the whole row and the rest of '
      'the row stays where it is and fades', (tester) async {
    const landing = Key('landing');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Builder(
              builder: (tile) => GestureDetector(
                onTap: () => openContainer<void>(
                  tile,
                  from: tile,
                  builder: (_) => const Scaffold(
                    key: _page,
                    body: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: EdgeInsets.only(top: 60),
                        child: ContainerLanding(
                          child: SizedBox(
                            key: landing,
                            width: 300,
                            height: 200,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const ContainerSource(
                  child: SizedBox(
                    width: 600,
                    height: 80,
                    child: Row(
                      children: [
                        Expanded(child: Text('name')),
                        ContainerHero(
                          child: SizedBox(
                            width: 90,
                            height: 60,
                            child: Text('art'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final row = tester.getRect(find.byType(ContainerSource));
    final art = tester.getRect(find.text('art'));
    // The picture on its way, and the rest of the row in the route's copy.
    final flying = find.descendant(
      of: find.byType(FittedBox),
      matching: find.text('art'),
    );
    final rest = find.descendant(
      of: find.byType(Navigator),
      matching: find.text('name'),
    );
    Rect restAt() => tester.getRect(rest.last);

    await tester.tap(find.text('name'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    // It opens out of the whole row, and the picture starts where it stands
    // in the row: at its end, not in the row's middle.
    final box = tester.getRect(find.byKey(ContainerPageRoute.boxKey));
    expect(box.width, greaterThanOrEqualTo(row.width));
    expect(box.width, lessThan(row.width + 60));
    expect((tester.getRect(flying).center - art.center).distance, lessThan(12));
    final nameAt = restAt();

    Rect? last;
    var seen = 0;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (flying.evaluate().isEmpty) {
        break;
      }
      seen++;
      last = tester.getRect(flying);
      final box = tester
          .getRect(find.byKey(ContainerPageRoute.boxKey))
          .inflate(1);
      expect(
        box.contains(last.topLeft) && box.contains(last.bottomRight),
        isTrue,
        reason: 'frame $i: $last outside $box',
      );
      // The rest of the row does not go with it.
      if (rest.evaluate().length > 1) {
        expect(restAt(), nameAt, reason: 'frame $i');
      }
    }
    expect(seen, greaterThan(3));
    await tester.pumpAndSettle();
    final own = tester.getRect(find.byKey(landing));
    expect((last!.center - own.center).distance, lessThan(12));
    expect(last.width, closeTo(own.width, 12));

    // And back into its own place in the row.
    await tester.binding.handlePopRoute();
    await tester.pump();
    for (var i = 0; i < 40 && find.byKey(_page).evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (flying.evaluate().isNotEmpty) {
        last = tester.getRect(flying);
      }
    }
    await tester.pumpAndSettle();
    expect((last!.center - art.center).distance, lessThan(12));
    expect(find.byKey(_page), findsNothing);
  });

  testWidgets('a busy button narrows to a spinner and takes no taps', (
    tester,
  ) async {
    var taps = 0;
    Widget button(bool busy) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: 300,
          child: BusyButton(
            busy: busy,
            onPressed: () => taps++,
            child: const Text('pay'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(button(false));
    expect(tester.getSize(find.byType(FilledButton)).width, 300);
    await tester.tap(find.text('pay'));
    expect(taps, 1);

    await tester.pumpWidget(button(true));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.getSize(find.byType(FilledButton)).width, lessThan(80));
    expect(find.text('pay'), findsNothing);
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    expect(taps, 1);
  });

  testWidgets('a figure counts to its new value', (tester) async {
    Widget figure(int value) => MaterialApp(
      home: CountUp(value: value, builder: (_, shown) => Text('$shown')),
    );
    await tester.pumpWidget(figure(100));
    // Its first value is simply shown.
    expect(find.text('100'), findsOneWidget);
    await tester.pumpWidget(figure(200));
    await tester.pump(const Duration(milliseconds: 200));
    final midway = int.parse(tester.widget<Text>(find.byType(Text)).data!);
    expect(midway, inExclusiveRange(100, 200));
    await tester.pumpAndSettle();
    expect(find.text('200'), findsOneWidget);
  });
}

class _Counted extends StatefulWidget {
  const _Counted({required this.onBuild, required this.onMove});

  final VoidCallback onBuild;
  final VoidCallback onMove;

  @override
  State<_Counted> createState() => _CountedState();
}

class _CountedState extends State<_Counted> {
  @override
  void activate() {
    super.activate();
    widget.onMove();
  }

  @override
  Widget build(BuildContext context) {
    widget.onBuild();
    return const Scaffold(
      key: _page,
      body: Center(child: Text('opened')),
    );
  }
}
