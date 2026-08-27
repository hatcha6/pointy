import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/analytics_interaction_tracker.dart';

/// The second-largest Flutter error in the field — 241 of them — came from the
/// telemetry code itself, reading `.widget` off a focused element the framework
/// had already unmounted.
void main() {
  testWidgets('names the focused widget while it is in the tree', (
    tester,
  ) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            captured = context;
            return const Placeholder();
          },
        ),
      ),
    );

    expect(focusedWidgetTypeName(captured), 'Builder');
  });

  testWidgets('an unmounted element yields no name instead of throwing', (
    tester,
  ) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            captured = context;
            return const Placeholder();
          },
        ),
      ),
    );

    // Take it out of the tree. The element is now defunct: `context.widget`
    // throws "Null check operator used on a null value" from here on.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    expect(focusedWidgetTypeName(captured), isNull);
    expect(tester.takeException(), isNull);
  });

  test('no context at all is not a focus target', () {
    expect(focusedWidgetTypeName(null), isNull);
  });
}
