import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/app.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/learning/engine/lesson.dart';
import 'package:pointy_frontend/src/features/learning/engine/lesson_runner.dart';
import 'package:pointy_frontend/src/features/learning/lessons/lessons.dart';
import 'package:pointy_frontend/src/features/learning/sandbox/sandbox_client.dart';
import 'package:pointy_frontend/src/features/learning/sandbox/seeds/seeds.dart';
import 'package:pointy_frontend/src/shared/tutor/tutor_target.dart';

/// Every lesson, run headlessly through the real app against the sandbox.
///
/// This is the half of the plan that makes the module maintainable: the same
/// lesson file the learner reads is *performed* here, step by step, against the
/// real screens. Move a button, rename a flow, change the API contract, and the
/// lesson breaks in CI — on the PR that broke it — instead of in front of a
/// cashier who cannot tell software from their own mistake.
///
/// The four ways a lesson rots, each with its own assertion below:
///
/// 1. **The anchor stops mounting.** The screen was redesigned and the control
///    the step points at is gone, so the ring is drawn over empty space.
/// 2. **The anchor becomes ambiguous.** A single control became a list, so a
///    step with no instance id now points at an arbitrary one of them.
/// 3. **The step becomes free.** Something else on the screen already satisfies
///    it, so it completes before the learner acts and the narration silently
///    falls one step behind what they are doing.
/// 4. **The shop stops moving.** Every step passes, and the sale never
///    happened. The screen can lie; the ledger cannot.
void main() {
  for (final lesson in allLessons) {
    testWidgets('lesson ${lesson.id} completes against the sandbox', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final shop = buildSandboxShop(lesson.seed);
      final client = SandboxClient(shop);
      final registry = TutorRegistry();
      addTearDown(registry.dispose);

      await tester.pumpWidget(
        TutorScope(
          registry: registry,
          child: PointyApp(apiService: PosApiService(client: client)),
        ),
      );
      await _settle(tester);

      final runner = LessonRunner(
        lesson: lesson,
        shop: shop,
        registry: registry,
      );
      addTearDown(runner.dispose);

      // (4), stated up front: a lesson whose outcome is already true before
      // the learner touches anything proves nothing, however green it runs.
      expect(
        runner.isOutcomeSatisfied,
        isFalse,
        reason:
            'lesson ${lesson.id} starts with its outcome already satisfied, '
            'so completing it demonstrates nothing: ${lesson.outcome.describe()}',
      );

      var guard = 0;
      while (!runner.isFinished) {
        if (guard++ > lesson.steps.length + 2) {
          fail(
            'lesson ${lesson.id} stopped advancing at step ${runner.stepIndex}',
          );
        }
        final index = runner.stepIndex;
        final step = runner.currentStep!;

        // (1)
        expect(
          registry.isMounted(step.anchor, id: step.anchorId),
          isTrue,
          reason:
              'step $index of ${lesson.id} points at ${step.target}, which '
              'never mounted — a spotlight over empty space',
        );

        // (2)
        if (step.anchorId == null) {
          expect(
            registry.countOf(step.anchor),
            1,
            reason:
                'step $index of ${lesson.id} names ${step.anchor.name} with no '
                'instance id, but ${registry.countOf(step.anchor)} are on '
                'screen — the ring would land on an arbitrary one. Give the '
                'step an anchorId.',
          );
        }

        // (3) — except for an explanation step, whose expectation describes
        // what should be on screen *while* it is read, and is true throughout.
        if (step.act is! TutorObserve) {
          expect(
            step.expect.isSatisfiedBy(runner.state),
            isFalse,
            reason:
                'step $index of ${lesson.id} is already satisfied before the '
                'learner acts, so it will skip itself and the narration will '
                'describe the previous screen: ${step.expect.describe()}',
          );
        }

        await _perform(tester, registry, runner, step);
        await _settle(tester);

        expect(
          step.expect.isSatisfiedBy(runner.state),
          isTrue,
          reason:
              'step $index of ${lesson.id} did not reach: '
              '${step.expect.describe()}',
        );
        expect(runner.tryAdvance(), isTrue);
      }

      // (4)
      expect(
        runner.isOutcomeSatisfied,
        isTrue,
        reason:
            'lesson ${lesson.id} finished but the shop disagrees: '
            '${runner.describeUnsatisfiedOutcome()}',
      );

      // A lesson that reached a 501 was teaching against a route the practice
      // shop does not implement — a blank screen waiting to happen.
      expect(
        client.unhandled,
        isEmpty,
        reason: 'lesson ${lesson.id} hit unimplemented sandbox routes',
      );
    });
  }
}

Future<void> _perform(
  WidgetTester tester,
  TutorRegistry registry,
  LessonRunner runner,
  TutorStep step,
) async {
  final context = registry.contextOf(step.anchor, id: step.anchorId);
  expect(context, isNotNull, reason: 'anchor ${step.target} not mounted');
  final finder = find.byWidget(context!.widget);

  // A long form puts the next control below the fold. A learner scrolls to it
  // without thinking; the runner has to be told, or the tap lands on whatever
  // is at those coordinates instead.
  await tester.ensureVisible(finder);
  await tester.pump();

  switch (step.act) {
    case TutorTap():
      await tester.tap(finder, warnIfMissed: false);
    case TutorType(:final text):
      await tester.enterText(
        find.descendant(of: finder, matching: find.byType(EditableText)).first,
        text,
      );
    case TutorObserve():
      // The learner presses "understood"; the runner does it for them.
      runner.acknowledge();
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}
