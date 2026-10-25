import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/shared/tilt_card.dart';

void main() {
  late StreamController<(double, double, double)> sensor;

  setUp(() {
    sensor = StreamController<(double, double, double)>.broadcast();
    TiltCard.source = () => sensor.stream;
  });
  tearDown(() => sensor.close());

  Future<void> pumpCard(WidgetTester tester, {bool still = false}) =>
      tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: still),
          child: const Directionality(
            textDirection: TextDirection.rtl,
            child: Center(
              child: TiltCard(
                radius: 16,
                child: SizedBox(width: 160, height: 100),
              ),
            ),
          ),
        ),
      );

  Matrix4 lean(WidgetTester tester) => tester
      .widget<Transform>(
        find.descendant(
          of: find.byType(TiltCard),
          matching: find.byType(Transform),
        ),
      )
      .transform;

  Future<void> hold(
    WidgetTester tester,
    (double, double, double) g,
    int n,
  ) async {
    for (var i = 0; i < n; i++) {
      sensor.add(g);
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('tipping the phone leans the card, then it settles flat', (
    tester,
  ) async {
    await pumpCard(tester);
    // Held flat: that is level, whatever the angle.
    await hold(tester, (0, 9.81, 0), 20);
    expect(lean(tester).getRotation().isIdentity(), isTrue);

    // Tipped sideways: the card turns with it.
    await hold(tester, (3, 9.3, 0), 20);
    expect(lean(tester).getRotation().isIdentity(), isFalse);

    // Held there: the new angle becomes level and the card eases back.
    await hold(tester, (3, 9.3, 0), 1500);
    final settled = lean(tester).getRotation();
    expect(settled.entry(0, 2).abs(), lessThan(0.01));
  });

  testWidgets('held upright, tipping it forwards leans the card back', (
    tester,
  ) async {
    await pumpCard(tester);
    // Upright in the hand, leaning back a little.
    await hold(tester, (0, 9.2, 3.4), 20);
    expect(lean(tester).getRotation().isIdentity(), isTrue);
    // Top tipped away (about 12 degrees): gravity moves into the depth.
    await hold(tester, (0, 8.4, 5.1), 40);
    final rotation = lean(tester).getRotation();
    // A turn about the card's own horizontal axis, and a real one.
    expect(rotation.entry(1, 2).abs(), greaterThan(0.05));
    expect(rotation.entry(0, 2).abs(), lessThan(0.01));
  });

  testWidgets('a small turn of the wrist is plainly visible', (tester) async {
    await pumpCard(tester);
    await hold(tester, (0, 9.81, 0), 10);
    // Ten degrees to the side.
    await hold(tester, (1.7, 9.66, 0), 30);
    // The card turns about eight degrees with it: nearly one to one.
    final sideways = lean(tester).getRotation().entry(0, 2).abs();
    expect(sideways, greaterThan(math.sin(7 * math.pi / 180)));
    expect(sideways, lessThan(math.sin(15 * math.pi / 180)));
  });

  testWidgets('a hand holding still moves nothing', (tester) async {
    await pumpCard(tester);
    await hold(tester, (0, 9.2, 3.4), 20);
    // A degree or so of wobble either way.
    for (var i = 0; i < 30; i++) {
      await hold(tester, i.isEven ? (0.15, 9.2, 3.5) : (-0.15, 9.2, 3.3), 1);
    }
    // Under a fifth of a degree: nothing the eye can see.
    expect(lean(tester).getRotation().entry(0, 2).abs(), lessThan(0.0035));
    expect(lean(tester).getRotation().entry(1, 2).abs(), lessThan(0.0035));
  });

  testWidgets('reduce motion keeps the card flat', (tester) async {
    await pumpCard(tester, still: true);
    await hold(tester, (0, 9.81, 0), 10);
    await hold(tester, (4, 9, 0), 20);
    expect(lean(tester).getRotation().isIdentity(), isTrue);
  });
}
