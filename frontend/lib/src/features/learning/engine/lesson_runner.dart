import 'package:flutter/foundation.dart';

import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../sandbox/sandbox_shop.dart';
import 'lesson.dart';

/// Drives one lesson: which step we are on, whether it is satisfied, and when
/// the whole thing is done.
///
/// Shared by both consumers the plan names — the coach panel watches it and
/// waits for the learner, the CI runner performs each act and then asks it the
/// same questions. One implementation, so a lesson cannot pass in CI and be
/// wrong in front of a person.
class LessonRunner extends ChangeNotifier {
  LessonRunner({
    required this.lesson,
    required this.shop,
    required this.registry,
  }) {
    registry.addListener(_onRegistryChanged);
  }

  final TutorLesson lesson;
  final SandboxShop shop;
  final TutorRegistry registry;

  int _stepIndex = 0;
  int get stepIndex => _stepIndex;

  bool _finished = false;
  bool get isFinished => _finished;

  TutorStep? get currentStep =>
      _stepIndex < lesson.steps.length ? lesson.steps[_stepIndex] : null;

  int get stepCount => lesson.steps.length;

  TutorState get state => TutorState(
    shop: shop,
    countOf: registry.countOf,
    textOf: registry.textOf,
  );

  /// How far the learner has said "understood".
  ///
  /// Only [TutorObserve] steps need it: a step that asks the learner to
  /// *notice* something has nothing to wait for, so without an explicit
  /// acknowledgement the engine would advance past the explanation before it
  /// had been read.
  int _acknowledgedStep = -1;

  void acknowledge() {
    if (_acknowledgedStep >= _stepIndex) {
      return;
    }
    _acknowledgedStep = _stepIndex;
    notifyListeners();
  }

  bool get isAwaitingAcknowledgement =>
      currentStep?.act is TutorObserve && _acknowledgedStep < _stepIndex;

  /// Whether the current step's expectation is already true.
  ///
  /// An observe step also needs the learner to have said so — its expectation
  /// describes what should be on screen while they read, and is true the whole
  /// time.
  bool get isCurrentStepSatisfied {
    final step = currentStep;
    if (step == null) {
      return false;
    }
    if (step.act is TutorObserve && _acknowledgedStep < _stepIndex) {
      return false;
    }
    return step.expect.isSatisfiedBy(state);
  }

  /// Whether the anchor the learner is being pointed at is on screen. False
  /// means the coach panel must say so rather than draw a spotlight over
  /// nothing.
  bool get isCurrentAnchorMounted {
    final step = currentStep;
    return step != null && registry.isMounted(step.anchor, id: step.anchorId);
  }

  /// Advances if — and only if — the current step is satisfied. Returns whether
  /// it moved, so the CI runner can fail loudly instead of silently looping.
  bool tryAdvance() {
    if (_finished || !isCurrentStepSatisfied) {
      return false;
    }
    _stepIndex++;
    if (_stepIndex >= lesson.steps.length) {
      _finished = true;
    }
    notifyListeners();
    return true;
  }

  /// The lesson's own verdict on the shop, independent of the screen.
  bool get isOutcomeSatisfied => lesson.outcome.isSatisfiedBy(state);

  /// Names what is still missing, for a test report.
  String describeUnsatisfiedOutcome() {
    final outcome = lesson.outcome;
    if (outcome is TutorExpectAll) {
      final missing = outcome.firstUnsatisfied(state);
      if (missing != null) {
        return missing.describe();
      }
    }
    return outcome.describe();
  }

  /// Anchors the lesson names that never mounted during this run — the check
  /// that turns a spotlight over empty space into a failing test.
  Set<TutorAnchor> get anchorsNeverSeen =>
      lesson.anchors.difference(_seenAnchors);

  final Set<TutorAnchor> _seenAnchors = {};

  void _onRegistryChanged() {
    _seenAnchors.addAll(registry.mountedAnchors);
    // A step can complete because the world changed, not because the learner
    // acted again — a checkout that lands, a sheet that opens.
    notifyListeners();
  }

  /// Re-checks the current step against the world.
  ///
  /// Not everything a step waits for is a registry event: typing into a field,
  /// a checkout landing in the sandbox, a total recomputing — none of those
  /// mount or unmount a [TutorTarget]. The hosting screen ticks this so the
  /// learner's progress is noticed however it happened; the CI runner calls
  /// [tryAdvance] directly after performing each act and needs no ticking,
  /// which is why the engine itself owns no timer.
  void reevaluate() {
    if (_finished) {
      return;
    }
    _seenAnchors.addAll(registry.mountedAnchors);
    if (isCurrentStepSatisfied) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    registry.removeListener(_onRegistryChanged);
    super.dispose();
  }
}
