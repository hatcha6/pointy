import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

/// Guards against the app's jank cause coming back.
///
/// Field telemetry from the first client showed build times under 2ms
/// everywhere against raster times of 15-20ms on the owner's screens. Nothing
/// was rebuilding — small things were animating, and because nothing isolated
/// them, the whole window was being redrawn to keep them company. These tests
/// pin the two structural fixes: animations own a layer, and the skeleton no
/// longer masks a screen.
void main() {
  group('animations do not repaint the page behind them', () {
    testWidgets('a spinner is its own layer', (tester) async {
      await _pump(tester, const PointySpinner(strokeWidth: 2));

      final boundary = tester.widget<RepaintBoundary>(
        find.descendant(
          of: find.byType(PointySpinner),
          matching: find.byType(RepaintBoundary),
        ),
      );
      expect(boundary.child, isA<CircularProgressIndicator>());
      expect(
        _nearestRepaintBoundary(tester, find.byType(CircularProgressIndicator)),
        isA<RenderRepaintBoundary>(),
      );
    });

    testWidgets('a progress bar is its own layer', (tester) async {
      await _pump(tester, const PointyProgressBar(value: 0.4));

      expect(
        _nearestRepaintBoundary(tester, find.byType(LinearProgressIndicator)),
        isA<RenderRepaintBoundary>(),
      );
    });

    testWidgets('every indeterminate placeholder owns a layer', (tester) async {
      await _pump(
        tester,
        const PointySkeleton(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PointySkeletonBox(height: 14),
              SizedBox(height: 8),
              PointySkeletonBox(width: 120, height: 12),
            ],
          ),
        ),
      );
      // Let the shimmer actually run a frame, so paint (and the screen-position
      // lookup it does) is exercised rather than merely constructed.
      await tester.pump(const Duration(milliseconds: 400));

      for (final element in find.byType(PointySkeletonBox).evaluate()) {
        final box = element.findRenderObject()! as RenderBox;
        expect(
          box.isRepaintBoundary,
          isTrue,
          reason: 'a shimmering placeholder must not dirty the page behind it',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a stopped skeleton does not pay for a layer', (tester) async {
      await _pump(
        tester,
        const PointySkeleton(
          enabled: false,
          child: PointySkeletonBox(width: 120, height: 12),
        ),
      );

      final box =
          tester.renderObject(find.byType(PointySkeletonBox)) as RenderBox;
      expect(box.isRepaintBoundary, isFalse);
    });
  });

  group('the skeleton does not mask a screen', () {
    testWidgets('no ShaderMask, so no full-window saveLayer', (tester) async {
      await _pump(
        tester,
        const PointySkeleton(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [PointySkeletonListTile(), PointySkeletonBox(height: 14)],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      // A ShaderMask forces a saveLayer the size of what it masks. Wrapping a
      // screenful of placeholders in one meant allocating and compositing a
      // full-window offscreen buffer at 60fps for as long as anything loaded.
      expect(find.byType(ShaderMask), findsNothing);
    });

    testWidgets('placeholders keep the sizes they had', (tester) async {
      await _pump(
        tester,
        const PointySkeleton(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PointySkeletonBox(height: 14),
              PointySkeletonBox(width: 120, height: 12),
              PointySkeletonBox.circle(size: 40),
            ],
          ),
        ),
      );

      final sizes = find
          .byType(PointySkeletonBox)
          .evaluate()
          .map((e) => (e.findRenderObject()! as RenderBox).size)
          .toList();
      // A null width still fills what it is offered; an explicit one wins.
      // These are the sizes the Container this replaced produced.
      expect(sizes[0], const Size(_surfaceWidth, 14));
      expect(sizes[1], const Size(120, 12));
      expect(sizes[2], const Size(40, 40));
    });

    testWidgets('a stretching parent still overrides an explicit width', (
      tester,
    ) async {
      await _pump(
        tester,
        const PointySkeleton(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [PointySkeletonBox(width: 120, height: 12)],
          ),
        ),
      );

      final box =
          tester.renderObject(find.byType(PointySkeletonBox)) as RenderBox;
      expect(box.size, const Size(_surfaceWidth, 12));
    });

    testWidgets('the highlight is painted and it moves', (tester) async {
      const key = ValueKey('shimmer');
      // runAsync: toImage is completed by the engine, not by the test's fake
      // clock, so awaiting it on the fake clock would hang forever.
      Future<Uint8List> shot() async {
        final boundary =
            tester.renderObject(find.byKey(key)) as RenderRepaintBoundary;
        final bytes = await tester.runAsync(() async {
          final image = await boundary.toImage();
          return image.toByteData(format: ui.ImageByteFormat.rawRgba);
        });
        return bytes!.buffer.asUint8List();
      }

      Future<void> pumpSkeleton({required bool enabled}) => _pump(
        tester,
        RepaintBoundary(
          key: key,
          child: PointySkeleton(
            enabled: enabled,
            child: const SizedBox(
              height: 40,
              child: PointySkeletonBox(height: 40, borderRadius: 0),
            ),
          ),
        ),
      );

      await pumpSkeleton(enabled: true);
      final atStart = await shot();
      // A third of the way through the 1350ms loop the highlight has swept onto
      // the box; if the gradient were not being applied these would match.
      await tester.pump(const Duration(milliseconds: 450));
      final laterOn = await shot();
      expect(laterOn, isNot(atStart));

      // And the lit frame differs from a stopped skeleton, so what moved really
      // is the highlight rather than some other repaint. Compared against the
      // lit frame and not against t=0: at the start of the cycle the sweep is
      // still off the box, which is exactly what a stopped one looks like.
      await pumpSkeleton(enabled: false);
      final stopped = await shot();
      expect(laterOn, isNot(stopped));
    });

    testWidgets('a box outside a skeleton still paints', (tester) async {
      await _pump(tester, const PointySkeletonBox(width: 80, height: 10));
      expect(tester.takeException(), isNull);
    });
  });

  test('no bare Material progress indicator is left in the app', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      // The one place allowed to build them: it is what adds the boundary.
      if (entity.path.endsWith('components/pointy_progress.dart')) {
        continue;
      }
      final source = entity.readAsStringSync();
      if (source.contains('CircularProgressIndicator(') ||
          source.contains('LinearProgressIndicator(')) {
        offenders.add(entity.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Use PointySpinner / PointyProgressBar. A bare indicator animates '
          'forever with no repaint boundary, so every tick redraws the whole '
          'window.',
    );
  });

  group('the shell gives its big, independent regions their own layer', () {
    // Typing into a list screen's search box re-recorded the whole page. The
    // field already had its own boundary, but the app bar above it and the
    // pane beside it did not, so the nearest picture holding those was the
    // route's — the entire window. The 2026-09-21 sweep measured the purchase
    // draft at 9.9 pictures re-recorded per keystroke frame covering 605% of
    // the window; with these two boundaries it is 7.9 and 366%. The catalog
    // is the same shape, and the app bar is on every screen in the app.
    testWidgets('the app bar does not share a layer with the page', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: PointyScaffold(
            appBar: PointyAppBar(title: Text('t')),
            body: Center(child: Text('body')),
          ),
        ),
      );
      expect(
        _isolatedFrom(tester, find.byType(AppBar), find.byType(Scaffold)),
        isTrue,
        reason:
            'PointyAppBar must own a layer: a toolbar spinner, an ink '
            'ripple or a rebuilt title otherwise re-records the whole route',
      );
    });

    testWidgets('each pane of a two-pane screen owns a layer', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TwoPaneLayout(
              primaryPane: Center(child: Text('primary')),
              secondaryPane: Center(child: Text('secondary')),
            ),
          ),
        ),
      );
      for (final label in ['primary', 'secondary']) {
        expect(
          _isolatedFrom(tester, find.text(label), find.byType(TwoPaneLayout)),
          isTrue,
          reason:
              'the $label pane must own a layer: the catalog and the '
              'draft change independently, and without one a keystroke on '
              'either re-records both',
        );
      }
    });
  });
}

const double _surfaceWidth = 360;

/// Deliberately themeless: what is asserted here is structural (layers, sizes,
/// the absence of a mask), and the palette falls back on its own. It also keeps
/// this file runnable on the compat branch, whose PointyTheme does not compile
/// against a current Flutter SDK.
Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Material(
          child: Center(
            child: SizedBox(width: _surfaceWidth, child: child),
          ),
        ),
      ),
    ),
  );
}

/// The layer an animation's `markNeedsPaint` would actually stop at. If this is
/// the root view, the animation is repainting the entire window.
/// Whether a repaint boundary sits strictly between [of] and [ancestor] — the
/// question "is this subtree isolated from that one", rather than the weaker
/// "some boundary exists somewhere above".
bool _isolatedFrom(WidgetTester tester, Finder of, Finder ancestor) {
  final stop = tester.renderObject(ancestor);
  RenderObject? node = tester.renderObject(of).parent;
  while (node != null && !identical(node, stop)) {
    if (node.isRepaintBoundary) {
      return true;
    }
    node = node.parent;
  }
  return false;
}

RenderObject _nearestRepaintBoundary(WidgetTester tester, Finder of) {
  RenderObject? node = tester.renderObject(of);
  while (node != null) {
    if (node.isRepaintBoundary) {
      return node;
    }
    node = node.parent;
  }
  fail('no repaint boundary above $of');
}
