import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/shared/container_route.dart';
import 'package:pointy_cards/src/shared/still_image.dart';

void main() {
  bool snapshotting(WidgetTester tester) => tester
      .widget<SnapshotWidget>(find.byType(SnapshotWidget))
      .controller
      .allowSnapshotting;

  testWidgets('a page is an image only while it moves', (tester) async {
    final opening = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 400),
    );
    final covered = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 400),
    );
    addTearDown(opening.dispose);
    addTearDown(covered.dispose);
    await tester.pumpWidget(
      TransitionSnapshot(
        animation: opening,
        secondary: covered,
        child: const ColoredBox(color: Color(0xFF00FF00)),
      ),
    );
    expect(snapshotting(tester), isFalse, reason: 'settled: live');

    opening.forward();
    await tester.pump();
    expect(snapshotting(tester), isTrue, reason: 'opening');
    await tester.pumpAndSettle();
    expect(snapshotting(tester), isFalse, reason: 'opened: live again');

    // Another page opening over it, then going away.
    covered.forward();
    await tester.pump();
    expect(snapshotting(tester), isTrue, reason: 'covered');
    await tester.pumpAndSettle();
    expect(snapshotting(tester), isFalse);
    covered.reverse();
    await tester.pump();
    expect(snapshotting(tester), isTrue, reason: 'uncovered');
    await tester.pumpAndSettle();
    expect(snapshotting(tester), isFalse);
  });

  testWidgets('off the web a still image is its child, untouched', (
    tester,
  ) async {
    await tester.pumpWidget(
      const StillImage(resolution: 0.25, child: SizedBox(width: 10)),
    );
    expect(find.byType(SnapshotWidget), findsNothing);
    expect(find.byType(SizedBox), findsOneWidget);
  });
}
