import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/features/learning/lessons/lessons.dart';
import 'package:pointy_frontend/src/features/learning/views/coach_panel.dart';
import 'package:pointy_frontend/src/features/learning/views/lesson_runner_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// The learner-facing half: the practice shop opens, says what to do, and is
/// unmistakably marked as not real.
void main() {
  testWidgets('the runner opens the practice shop behind a training banner', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(const LessonRunnerScreen(lesson: posCashSaleLesson)),
    );
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    // §9: unmissable, and never dismissible.
    expect(find.text('وضع التدريب — لا شيء هنا حقيقي'), findsOneWidget);

    // The coach narrates the first step...
    expect(find.text(posCashSaleLesson.title), findsOneWidget);
    expect(find.text(posCashSaleLesson.steps.first.say), findsOneWidget);
    expect(find.text('الخطوة 1 من 5'), findsOneWidget);

    // ...over the real register-session gate, served by the sandbox.
    expect(find.text('نقدية الافتتاح'), findsWidgets);
  });

  testWidgets('the coach advances only when the learner does the step', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(const LessonRunnerScreen(lesson: posCashSaleLesson)),
    );
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    // Still on step 1 after doing nothing.
    expect(find.text('الخطوة 1 من 5'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '50');
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.tap(find.text('بدء الجلسة'));
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    // Two steps done: the field, then the button that opened the session.
    expect(find.text('الخطوة 3 من 5'), findsOneWidget);
    expect(find.text(posCashSaleLesson.steps[2].say), findsOneWidget);
  });

  testWidgets('the ring lands on the control the step names', (tester) async {
    // The ring used to resolve its origin from whatever render object the
    // builder happened to find, which came back rooted at the screen — so it
    // drew the training banner's height too high, over the wrong widget. Only
    // comparing the painted rect to the anchor's own rect catches that.
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(const LessonRunnerScreen(lesson: posCashSaleLesson)),
    );
    await _settle(tester);

    final painted = _spotlightRect(tester);
    final field = tester.getRect(find.byType(TextField).first);
    final surface = tester.getTopLeft(_spotlightSurface());
    final expected = field.shift(-surface).inflate(3);

    expect((painted.left - expected.left).abs(), lessThan(1));
    expect((painted.top - expected.top).abs(), lessThan(1));
    expect((painted.width - expected.width).abs(), lessThan(1));
    expect((painted.height - expected.height).abs(), lessThan(1));
  });

  testWidgets('a step is not satisfied by acting on a different item', (
    tester,
  ) async {
    // "Tap خبز" has to mean خبز. An expectation that accepts any cart line
    // completes on a product the learner was never told to tap, and from then
    // on the narration describes something other than what is on screen.
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(const LessonRunnerScreen(lesson: posCashSaleLesson)),
    );
    await _settle(tester);

    await tester.enterText(find.byType(TextField).first, '50');
    await _settle(tester);
    await tester.tap(find.text('بدء الجلسة'));
    await _settle(tester);
    expect(find.text('الخطوة 3 من 5'), findsOneWidget);

    // The wrong product: it lands in the cart, but the step must not move.
    await tester.tap(find.text('حليب طازج ١ لتر').first);
    await _settle(tester);
    expect(find.text('الخطوة 3 من 5'), findsOneWidget);
    expect(find.text(posCashSaleLesson.steps[2].say), findsOneWidget);

    // The named one does.
    await tester.tap(find.text('خبز').first);
    await _settle(tester);
    expect(find.text('الخطوة 4 من 5'), findsOneWidget);
  });
}

Finder _spotlightSurface() => find.byWidgetPredicate(
  (widget) => widget is CustomPaint && widget.painter is TutorSpotlightPainter,
);

Rect _spotlightRect(WidgetTester tester) {
  final paint = tester.widgetList<CustomPaint>(_spotlightSurface()).single;
  return (paint.painter! as TutorSpotlightPainter).rect;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Widget _host(Widget child) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: PointyTheme.light(),
    home: child,
  );
}
