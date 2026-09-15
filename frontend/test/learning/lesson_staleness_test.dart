import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/features/learning/content/learning_library.dart';
import 'package:pointy_frontend/src/features/learning/engine/lesson.dart';
import 'package:pointy_frontend/src/features/learning/lessons/lessons.dart';
import 'package:pointy_frontend/src/features/learning/sandbox/sandbox_payloads.dart';
import 'package:pointy_frontend/src/features/learning/sandbox/seeds/seeds.dart';
import 'package:pointy_frontend/src/shared/tutor/anchors.dart';

/// The cheap half of anti-rot.
///
/// `lessons_test.dart` proves each lesson still *runs*; these are the checks
/// that do not need a widget tree, and that catch the rot which running a
/// lesson cannot see — an anchor nothing wraps any more, a guide whose practice
/// button now opens a lesson for a screen the practice account cannot reach, a
/// prerequisite that was renamed.
void main() {
  group('anchors', () {
    test('every anchor is wrapped somewhere in the app', () {
      // An enum value whose TutorTarget was deleted in a redesign still
      // compiles, and the lesson naming it only fails when it is run. This
      // names the anchor instead of the lesson.
      final wrapped = _anchorsUsedInApp();
      final orphans = TutorAnchor.values
          .where((anchor) => !wrapped.contains(anchor.name))
          .map((anchor) => anchor.name)
          .toList();
      expect(
        orphans,
        isEmpty,
        reason:
            'these anchors are declared but no TutorTarget wraps them, so a '
            'lesson naming one draws a ring over nothing: ${orphans.join(', ')}',
      );
    });

    test('every anchor is named by at least one lesson', () {
      // The other direction: anchors that survive a lesson being rewritten are
      // dead weight in feature screens, and dead weight is what stops being
      // maintained.
      // `lesson.anchors`, not just the step targets: an anchor a lesson only
      // *reads* ("the cart now names أحمد") is still proved by running it.
      final named = {for (final lesson in allLessons) ...lesson.anchors};
      final unused = TutorAnchor.values
          .where((anchor) => !named.contains(anchor))
          .map((anchor) => anchor.name)
          .toList();
      expect(
        unused,
        isEmpty,
        reason:
            'no lesson points at these anchors, so nothing proves they still '
            'work — use them or delete them: ${unused.join(', ')}',
      );
    });
  });

  group('lessons', () {
    test('ids are unique and namespaced', () {
      final ids = allLessons.map((lesson) => lesson.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'duplicate lesson id');
      for (final id in ids) {
        expect(id, contains('.'), reason: '$id should read track.lesson');
      }
    });

    test('every lesson links to a guide that exists', () {
      // The practice button lives on the guide. A renamed guide does not break
      // the build on its own — it just silently stops offering the practice.
      final guideIds = {for (final guide in learningLibrary) guide.id};
      for (final lesson in allLessons) {
        final guideId = lesson.guideId;
        expect(
          guideId,
          isNotNull,
          reason: 'lesson ${lesson.id} is unreachable: no guide opens it',
        );
        expect(
          guideIds,
          contains(guideId),
          reason: 'lesson ${lesson.id} points at missing guide $guideId',
        );
      }
    });

    test('prerequisites resolve and never loop', () {
      final byId = {for (final lesson in allLessons) lesson.id: lesson};
      for (final lesson in allLessons) {
        for (final required in lesson.requires) {
          expect(
            byId,
            contains(required),
            reason: '${lesson.id} requires $required, which does not exist',
          );
        }
      }
      // Depth-first, tracking the path: "open the register" requiring "close
      // the register" would otherwise hang the catalogue rather than fail.
      final settled = <String>{};
      void walk(String id, List<String> path) {
        if (settled.contains(id)) {
          return;
        }
        expect(
          path,
          isNot(contains(id)),
          reason: 'prerequisite loop: ${[...path, id].join(' → ')}',
        );
        for (final required in byId[id]!.requires) {
          walk(required, [...path, id]);
        }
        settled.add(id);
      }

      for (final lesson in allLessons) {
        walk(lesson.id, const []);
      }
    });

    test('the practice account can reach every lesson it is offered', () {
      // A back-office lesson seeded with the cashier opens on a permissions
      // message instead of a screen — which teaches the learner that the
      // software is broken, the one thing training must never do.
      for (final lesson in allLessons) {
        final capability = lesson.capability;
        if (capability == null) {
          continue;
        }
        final shop = buildSandboxShop(lesson.seed);
        final capabilities = AuthorizationCapabilities.forUser(
          PosUser.fromJson(userJson(shop)),
        );
        expect(
          capabilities.allows(capability),
          isTrue,
          reason:
              'lesson ${lesson.id} needs ${capability.name}, which the '
              '${shop.cashierRole} in seed ${lesson.seed.name} does not have',
        );
      }
    });

    test('every step says something, and the lesson ends somewhere', () {
      for (final lesson in allLessons) {
        expect(lesson.title.trim(), isNotEmpty);
        expect(lesson.summary.trim(), isNotEmpty);
        expect(
          lesson.steps.length,
          greaterThanOrEqualTo(2),
          reason: '${lesson.id} is not a task, it is a tap',
        );
        for (final (index, step) in lesson.steps.indexed) {
          expect(
            step.say.trim(),
            isNotEmpty,
            reason: 'step $index of ${lesson.id} narrates nothing',
          );
          expect(
            step.hint?.trim(),
            isNot(''),
            reason: 'step $index of ${lesson.id} has an empty hint',
          );
        }
        // The outcome is what separates a lesson from a guided tour.
        expect(
          lesson.outcome,
          isA<TutorExpectAll>(),
          reason:
              '${lesson.id} should assert several things about the shop, not '
              'one — a sale that moved stock but not the drawer is a bug the '
              'single-assertion version would pass',
        );
      }
    });
  });
}

/// Every `TutorAnchor.x` written outside the enum and the learning module —
/// that is, the ones a real screen actually wraps.
Set<String> _anchorsUsedInApp() {
  final pattern = RegExp(r'TutorAnchor\.([a-zA-Z0-9_]+)');
  final used = <String>{};
  for (final entity in Directory('lib/src').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) {
      continue;
    }
    if (entity.path.endsWith('shared/tutor/anchors.dart') ||
        entity.path.contains('features/learning/')) {
      continue;
    }
    for (final match in pattern.allMatches(entity.readAsStringSync())) {
      used.add(match.group(1)!);
    }
  }
  return used;
}
