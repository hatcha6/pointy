import 'package:animations/animations.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransition;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/features/brand/brand_page.dart';
import 'package:pointy_cards/src/shared/container_route.dart';
import 'package:pointy_cards/src/shared/motion.dart';

/// What Android sends as a finger drags back from the screen's edge.
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

Future<void> _openBrand(WidgetTester tester) async {
  await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
  await tester.pumpAndSettle();
  await tester.tap(find.text('ليبيانا').first);
}

void main() {
  group('a page that opens from another', () {
    testWidgets('comes forward on the shared axis on Android, and goes back '
        'the same way for a back button', (tester) async {
      await _openBrand(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SharedAxisTransition), findsWidgets);
      // Mid-flight, both pages are there.
      expect(find.byType(BrandPage), findsOneWidget);
      await tester.pumpAndSettle();

      // The system's back button, and every back button of the app's own.
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(BrandPage), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(BrandPage), findsNothing);
    });

    testWidgets('follows an Android back swipe, shows the page beneath, and '
        'leaves when the finger lets go', (tester) async {
      await _openBrand(tester);
      await tester.pumpAndSettle();
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );

      await _backGesture(tester, 'startBackGesture', 0);
      await _backGesture(tester, 'updateBackGestureProgress', 0.5);
      await tester.pump();
      expect(navigator.userGestureInProgress, isTrue);
      // The shelf beneath is on stage while the finger is down.
      expect(find.text('اكتشف الكروت'), findsOneWidget);
      expect(find.byType(BrandPage), findsOneWidget);

      await _backGesture(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.byType(BrandPage), findsNothing);
      expect(navigator.userGestureInProgress, isFalse);
    });

    testWidgets('stays when an Android back swipe is called off', (
      tester,
    ) async {
      await _openBrand(tester);
      await tester.pumpAndSettle();
      await _backGesture(tester, 'startBackGesture', 0);
      await _backGesture(tester, 'updateBackGestureProgress', 0.4);
      await tester.pump();
      await _backGesture(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      expect(find.byType(BrandPage), findsOneWidget);
      // And still answers a tap: nothing of the gesture is left over it.
      await tester.tap(find.text('10 دينار'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps the system slide on iOS, where a swipe from the edge '
        'drags it back', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await _openBrand(tester);
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoPageTransition), findsWidgets);
      // Right to left: the page is pulled back from the right edge.
      final width =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final gesture = await tester.startGesture(Offset(width - 2, 300));
      await gesture.moveBy(Offset(-width * 0.7, 0));
      await tester.pump();
      expect(find.byType(BrandPage), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byType(BrandPage), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  testWidgets('a «اشترِ مجدداً» tile opens its own brand out of itself, not '
      'out of the first tile of the strip', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
    await tester.pumpAndSettle();
    // The strip's cards: the small ones.
    final tiles = find.byWidgetPredicate(
      (w) => w is ContainerSource,
      description: 'buy-again card',
    );
    final small = [
      for (final element in tiles.evaluate())
        if (tester.getSize(find.byElementPredicate((e) => e == element)).width <
            100)
          element,
    ];
    expect(small.length, greaterThan(1));
    final second = find.byElementPredicate((e) => e == small[1]);
    final from = tester.getRect(second);
    await tester.tap(second);
    await tester.pump();
    await tester.pump();
    // The page's first frame is the tapped card's own box.
    expect(
      tester.getRect(find.byKey(ContainerPageRoute.boxKey)).topLeft,
      from.topLeft,
    );
    await tester.pumpAndSettle();
    expect(find.byType(BrandPage), findsOneWidget);
  });

  group('the tabs', () {
    Widget stack(int index, {Widget? second}) => MaterialApp(
      home: FadeThroughStack(
        index: index,
        children: [
          const _Counter(name: 'one'),
          second ?? const _Counter(name: 'two'),
        ],
      ),
    );

    testWidgets('fade through, and each keeps what it held', (tester) async {
      await tester.pumpWidget(stack(0));
      await tester.tap(find.text('one 0'));
      await tester.pump();
      expect(find.text('one 1'), findsOneWidget);

      await tester.pumpWidget(stack(1));
      await tester.pump(const Duration(milliseconds: 60));
      // The page left is still there, fading, and takes no taps.
      expect(find.text('one 1'), findsOneWidget);
      expect(find.text('two 0'), findsOneWidget);
      await tester.tap(find.text('one 1'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('one 1'), findsNothing);
      expect(find.text('one 1', skipOffstage: false), findsOneWidget);

      await tester.pumpWidget(stack(0));
      await tester.pumpAndSettle();
      expect(find.text('one 1'), findsOneWidget);
    });

    testWidgets('the page left fades as it was, whatever takes its place', (
      tester,
    ) async {
      await tester.pumpWidget(stack(1));
      await tester.pumpWidget(stack(0, second: const SizedBox.shrink()));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('two 0'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('two 0', skipOffstage: false), findsNothing);
    });

    testWidgets('change at once when the system asks for less motion', (
      tester,
    ) async {
      Widget still(int index) => MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: stack(index),
      );
      await tester.pumpWidget(still(0));
      await tester.pumpWidget(still(1));
      await tester.pump();
      expect(find.text('one 0'), findsNothing);
      expect(find.text('two 0'), findsOneWidget);
    });
  });

  testWidgets("a dialog fades and scales, and the system's back closes it", (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showCardsDialog<void>(
              context: context,
              builder: (_) => const AlertDialog(title: Text('sure?')),
            ),
            child: const Text('ask'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ask'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(FadeScaleTransition), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('sure?'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('sure?'), findsNothing);
  });

  testWidgets('a step forward moves with the reading direction', (
    tester,
  ) async {
    Widget steps(String step, TextDirection direction, {bool back = false}) =>
        MaterialApp(
          home: Directionality(
            textDirection: direction,
            child: CardsSwitcher(
              kind: SwitchKind.steps,
              back: back,
              child: Text(step, key: ValueKey(step)),
            ),
          ),
        );
    // Where the new step stands a moment after it starts coming in.
    Future<double> entering(
      TextDirection direction, {
      bool back = false,
    }) async {
      await tester.pumpWidget(steps('a', direction));
      await tester.pumpWidget(steps('b', direction, back: back));
      await tester.pump(const Duration(milliseconds: 100));
      final settled = tester.getCenter(find.byType(CardsSwitcher)).dx;
      final x = tester.getCenter(find.text('b')).dx - settled;
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      return x;
    }

    // Left to right, the next step comes in from the right; right to left,
    // from the left. Going back is the other way round.
    expect(await entering(TextDirection.ltr), greaterThan(0));
    expect(await entering(TextDirection.rtl), lessThan(0));
    expect(await entering(TextDirection.rtl, back: true), greaterThan(0));
  });
}

class _Counter extends StatefulWidget {
  const _Counter({required this.name});

  final String name;

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _taps = 0;

  @override
  Widget build(BuildContext context) => Center(
    child: GestureDetector(
      onTap: () => setState(() => _taps++),
      child: Text('${widget.name} $_taps'),
    ),
  );
}
