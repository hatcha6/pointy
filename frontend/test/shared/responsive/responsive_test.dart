import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';

void main() {
  group('AppBreakpoints', () {
    test('classifies the requested responsive ranges', () {
      expect(AppBreakpoints.forWidth(360), AppBreakpoint.phone);
      expect(AppBreakpoints.forWidth(430), AppBreakpoint.phone);
      expect(AppBreakpoints.forWidth(480), AppBreakpoint.largePhone);
      expect(AppBreakpoints.forWidth(719), AppBreakpoint.largePhone);
      expect(AppBreakpoints.forWidth(720), AppBreakpoint.tablet);
      expect(AppBreakpoints.forWidth(1023), AppBreakpoint.tablet);
      expect(AppBreakpoints.forWidth(1024), AppBreakpoint.desktop);
      expect(AppBreakpoints.forWidth(1366), AppBreakpoint.widePos);
    });
  });

  group('ResponsiveFormGrid', () {
    test('uses shared column limits for each breakpoint', () {
      expect(ResponsiveFormGrid.columnCountForWidth(430), 1);
      expect(ResponsiveFormGrid.columnCountForWidth(480), 2);
      expect(ResponsiveFormGrid.columnCountForWidth(719), 2);
      expect(ResponsiveFormGrid.columnCountForWidth(720), 3);
      expect(ResponsiveFormGrid.columnCountForWidth(1024), 3);
      expect(ResponsiveFormGrid.columnCountForWidth(1366, maxColumns: 5), 5);
    });

    test('computes item widths from the same column math', () {
      expect(
        ResponsiveFormGrid.itemWidthForWidth(720),
        closeTo((720 - 24) / 3, 0.01),
      );
      expect(
        ResponsiveFormGrid.itemWidthForWidth(480),
        closeTo((480 - 12) / 2, 0.01),
      );
    });
  });

  group('Adaptive sizing', () {
    test('resolves shared pane and modal widths', () {
      expect(AppPaneWidths.trailingPaneForWidth(430), 430);
      expect(AppPaneWidths.trailingPaneForWidth(720), 420);
      expect(AppPaneWidths.trailingPaneForWidth(1366), 520);
      expect(AdaptiveModalSizing.maxWidthFor(360), 360);
      expect(AdaptiveModalSizing.maxWidthFor(1024), 720);
      expect(
        AdaptiveModalSizing.maxWidthFor(1024, size: AdaptiveModalSize.expanded),
        860,
      );
    });
  });

  group('TwoPaneLayout', () {
    testWidgets('stacks below tablet width and splits at tablet width', (
      tester,
    ) async {
      const primaryKey = Key('primary-pane');
      const secondaryKey = Key('secondary-pane');

      await _pumpSurface(
        tester,
        width: 719,
        height: 600,
        child: const TwoPaneLayout(
          primaryPane: SizedBox.expand(
            child: ColoredBox(key: primaryKey, color: Colors.teal),
          ),
          secondaryPane: SizedBox.expand(
            child: ColoredBox(key: secondaryKey, color: Colors.amber),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(primaryKey)).width, 719);
      expect(tester.getSize(find.byKey(secondaryKey)).width, 719);

      await _pumpSurface(
        tester,
        width: 720,
        height: 600,
        child: const TwoPaneLayout(
          primaryPane: SizedBox.expand(
            child: ColoredBox(key: primaryKey, color: Colors.teal),
          ),
          secondaryPane: SizedBox.expand(
            child: ColoredBox(key: secondaryKey, color: Colors.amber),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(secondaryKey)).width, 420);
      expect(tester.getSize(find.byKey(primaryKey)).width, lessThan(400));
    });
  });

  group('ResponsiveActionBar', () {
    testWidgets('stretches actions on phone and keeps intrinsic width at 480', (
      tester,
    ) async {
      const firstKey = Key('first-action');
      const secondKey = Key('second-action');

      await _pumpSurface(
        tester,
        width: 430,
        height: 120,
        child: const ResponsiveActionBar(
          actions: [
            SizedBox(key: firstKey, width: 100, height: 32),
            SizedBox(key: secondKey, width: 100, height: 32),
          ],
        ),
      );

      expect(tester.getSize(find.byKey(firstKey)).width, 430);
      expect(tester.getSize(find.byKey(secondKey)).width, 430);

      await _pumpSurface(
        tester,
        width: 480,
        height: 120,
        child: const ResponsiveActionBar(
          actions: [
            SizedBox(key: firstKey, width: 100, height: 32),
            SizedBox(key: secondKey, width: 100, height: 32),
          ],
        ),
      );

      expect(tester.getSize(find.byKey(firstKey)).width, 100);
      expect(tester.getSize(find.byKey(secondKey)).width, 100);
    });
  });
}

Future<void> _pumpSurface(
  WidgetTester tester, {
  required double width,
  required double height,
  required Widget child,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Center(
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    ),
  );
}
