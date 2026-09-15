import '../../../core/authorization.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import 'expectations.dart';

export 'expectations.dart';

/// Which starting shop a lesson runs against.
///
/// Two profiles over one shop, not two shops: the products, prices and stock a
/// learner has to hold in their head stay the same whichever lesson they open,
/// and only the signed-in practice user changes. A cashier cannot reach the
/// catalogue or purchasing, so a back-office lesson seeded with one would open
/// on a screen the learner is not allowed to see.
enum SandboxSeed {
  groceryMorning,
  groceryBackOffice,
  groceryBackOfficeWithOrder,
  groceryBackOfficeWithDelivery,
}

/// What the learner does at a step.
///
/// The engine never performs these for the learner — a lesson you watch is a
/// lesson you have not learned. The CI runner performs them, which is how the
/// same file proves the lesson still works.
sealed class TutorAct {
  const TutorAct();

  /// Tap the step's anchor.
  const factory TutorAct.tap() = TutorTap;

  /// Type [text] into the step's anchor.
  const factory TutorAct.type(String text) = TutorType;

  /// Nothing to do — the step is something to read or notice.
  const factory TutorAct.observe() = TutorObserve;
}

class TutorTap extends TutorAct {
  const TutorTap();
}

class TutorType extends TutorAct {
  const TutorType(this.text);

  final String text;
}

class TutorObserve extends TutorAct {
  const TutorObserve();
}

/// One thing the learner does, narrated.
class TutorStep {
  const TutorStep({
    required this.say,
    required this.anchor,
    required this.act,
    required this.expect,
    this.anchorId,
    this.hint,
  });

  /// The narration, in Arabic, shown in the coach panel.
  final String say;

  /// What to spotlight, and what [act] is performed on.
  final TutorAnchor anchor;

  /// Which instance of [anchor], when a screen has many. Naming a product in
  /// the narration and spotlighting an arbitrary tile is worse than not
  /// spotlighting at all.
  final String? anchorId;

  TutorTargetId get target => TutorTargetId(anchor, anchorId);

  final TutorAct act;

  /// What must become true before the step is complete.
  final TutorExpect expect;

  /// Shown after the learner has been stuck for a while.
  final String? hint;
}

/// A lesson: a real task, narrated, run against a sandbox shop.
class TutorLesson {
  const TutorLesson({
    required this.id,
    required this.title,
    required this.summary,
    required this.seed,
    required this.steps,
    required this.outcome,
    this.capability,
    this.guideId,
    this.requires = const <String>[],
  });

  final String id;
  final String title;
  final String summary;
  final SandboxSeed seed;
  final List<TutorStep> steps;

  /// What must be true about the *shop* when the lesson ends. The screen can
  /// lie; the ledger cannot.
  final TutorExpect outcome;

  final AppCapability? capability;

  /// The written guide this lesson practises, so the two stay linked.
  final String? guideId;

  /// Lessons worth doing first. Not a gate — a learner who wants to jump
  /// straight to "close the register" may — but the reader says so, and CI
  /// checks the ids resolve and never loop.
  final List<String> requires;

  /// Every anchor the lesson depends on: the ones it points at, and the ones
  /// its expectations read. CI asserts all of them still exist.
  Set<TutorAnchor> get anchors => {
    for (final step in steps) ...[step.anchor, ...step.expect.anchorsRead],
    ...outcome.anchorsRead,
  };
}
