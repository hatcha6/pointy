import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../engine/lesson_runner.dart';

/// The narration track beside the practice shop.
///
/// It says what to do and waits. It never performs the step for the learner —
/// a lesson you watch is a lesson you have not learned — so the only
/// escalation here is a hint after a while, and a ring drawn round the control.
class CoachPanel extends StatefulWidget {
  const CoachPanel({
    super.key,
    required this.runner,
    required this.onExit,
    required this.onRestart,
  });

  final LessonRunner runner;
  final VoidCallback onExit;
  final VoidCallback onRestart;

  @override
  State<CoachPanel> createState() => _CoachPanelState();
}

class _CoachPanelState extends State<CoachPanel> {
  /// How long a learner may be stuck before the hint appears. Long enough that
  /// someone reading the step is not interrupted, short enough to rescue
  /// someone who has re-read it twice.
  static const _hintDelay = Duration(seconds: 20);

  Timer? _hintTimer;
  bool _showHint = false;
  int _hintStepIndex = -1;

  @override
  void initState() {
    super.initState();
    widget.runner.addListener(_onRunnerChanged);
    _restartHintTimer();
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    widget.runner.removeListener(_onRunnerChanged);
    super.dispose();
  }

  void _onRunnerChanged() {
    if (widget.runner.stepIndex != _hintStepIndex) {
      _restartHintTimer();
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _restartHintTimer() {
    _hintTimer?.cancel();
    _showHint = false;
    _hintStepIndex = widget.runner.stepIndex;
    _hintTimer = Timer(_hintDelay, () {
      if (mounted) {
        setState(() => _showHint = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final runner = widget.runner;
    final step = runner.currentStep;

    return Material(
      color: colors.surface,
      child: Padding(
        padding: EdgeInsets.all(spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    runner.lesson.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  l10n.lessonStepProgress(
                    (runner.stepIndex + 1).clamp(1, runner.stepCount),
                    runner.stepCount,
                  ),
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: colors.mutedInk),
                ),
              ],
            ),
            SizedBox(height: spacing.sm),
            PointyProgressBar(
              value: runner.stepCount == 0
                  ? 0
                  : runner.stepIndex / runner.stepCount,
              minHeight: 6,
              backgroundColor: colors.surfaceSunken,
            ),
            SizedBox(height: spacing.md),
            if (runner.isFinished)
              _Finished(onExit: widget.onExit, onRestart: widget.onRestart)
            else if (step != null) ...[
              Text(
                step.say,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(height: 1.6),
              ),
              if (!runner.isCurrentAnchorMounted) ...[
                SizedBox(height: spacing.sm),
                Text(
                  l10n.lessonAnchorOffScreen,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.warning),
                ),
              ],
              if (_showHint && step.hint != null) ...[
                SizedBox(height: spacing.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.lightbulb_outline,
                      size: 18,
                      color: colors.primaryStrong,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        step.hint!,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (runner.isAwaitingAcknowledgement) ...[
                SizedBox(height: spacing.md),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.icon(
                    onPressed: runner.acknowledge,
                    icon: const Icon(Icons.done),
                    label: Text(l10n.lessonUnderstoodButton),
                  ),
                ),
              ],
              SizedBox(height: spacing.md),
              // Wrap, not Row: two Arabic button labels plus their icons do not
              // fit the 360px coach column side by side.
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: spacing.sm,
                children: [
                  TextButton.icon(
                    onPressed: widget.onRestart,
                    icon: const Icon(Icons.refresh),
                    label: Text(l10n.lessonRestartButton),
                  ),
                  TextButton.icon(
                    onPressed: widget.onExit,
                    icon: const Icon(Icons.close),
                    label: Text(l10n.lessonExitButton),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Finished extends StatelessWidget {
  const _Finished({required this.onExit, required this.onRestart});

  final VoidCallback onExit;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle, color: colors.success),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.lessonCompleteTitle,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colors.success,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(l10n.lessonCompleteMessage),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: onRestart,
              icon: const Icon(Icons.refresh),
              label: Text(l10n.lessonRestartButton),
            ),
            FilledButton.icon(
              onPressed: onExit,
              icon: const Icon(Icons.check),
              label: Text(l10n.lessonExitButton),
            ),
          ],
        ),
      ],
    );
  }
}

/// Draws a ring round the control the current step points at.
///
/// Non-blocking on purpose: a modal dim would stop the learner touching the
/// very thing they are being told to touch, and the point is that they do it
/// themselves.
class TutorSpotlight extends StatefulWidget {
  const TutorSpotlight({
    super.key,
    required this.registry,
    required this.runner,
  });

  final TutorRegistry registry;
  final LessonRunner runner;

  @override
  State<TutorSpotlight> createState() => _TutorSpotlightState();
}

class _TutorSpotlightState extends State<TutorSpotlight> {
  /// Identifies the painting surface itself.
  ///
  /// The previous version asked the builder's own `BuildContext` for a render
  /// object, which resolves to whatever happens to be first in that subtree —
  /// on a frame where the child was a `SizedBox.shrink` it came back rooted at
  /// the screen origin, and the ring drew a banner's height too high. A
  /// GlobalKey names exactly one box, and `globalToLocal` converts through it
  /// correctly even under a transform.
  final GlobalKey _surfaceKey = GlobalKey();

  Rect? _rect;

  int _revealedStep = -1;

  @override
  void initState() {
    super.initState();
    widget.registry.addListener(_schedule);
    widget.runner.addListener(_schedule);
    _schedule();
  }

  @override
  void dispose() {
    widget.registry.removeListener(_schedule);
    widget.runner.removeListener(_schedule);
    super.dispose();
  }

  /// Measures after layout, never during build: the anchor's box has no size
  /// until the frame it is laid out in.
  void _schedule() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _measure();
      }
    });
  }

  void _measure() {
    if (_revealedStep != widget.runner.stepIndex) {
      _revealedStep = widget.runner.stepIndex;
      _revealCurrentStep();
    }
    final next = _resolveRect();
    if (next != _rect) {
      setState(() => _rect = next);
    }
  }

  /// Scrolls the step's control into view.
  ///
  /// A long form — the product wizard, the payment sheet on a small till —
  /// puts the next control below the fold, and a ring the learner cannot see
  /// is a ring that is not helping. Only on a step change: doing it every
  /// measurement would fight the learner's own scrolling.
  void _revealCurrentStep() {
    final step = widget.runner.currentStep;
    final context = step == null
        ? null
        : widget.registry.contextOf(step.anchor, id: step.anchorId);
    if (context == null || !context.mounted) {
      return;
    }
    Scrollable.ensureVisible(
      context,
      alignment: 0.5,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Rect? _resolveRect() {
    final step = widget.runner.currentStep;
    if (step == null || widget.runner.isFinished) {
      return null;
    }
    final surface = _surfaceKey.currentContext?.findRenderObject();
    final anchor = widget.registry.renderBoxOf(step.anchor, id: step.anchorId);
    if (surface is! RenderBox || !surface.hasSize || anchor == null) {
      return null;
    }
    final topLeft = surface.globalToLocal(anchor.localToGlobal(Offset.zero));
    final bottomRight = surface.globalToLocal(
      anchor.localToGlobal(anchor.size.bottomRight(Offset.zero)),
    );
    return Rect.fromPoints(topLeft, bottomRight);
  }

  @override
  Widget build(BuildContext context) {
    final rect = _rect;
    return IgnorePointer(
      // A scroll moves the anchor without touching the registry, so re-measure
      // on any scroll beneath us rather than leave the ring behind.
      child: NotificationListener<ScrollNotification>(
        onNotification: (_) {
          _schedule();
          return false;
        },
        child: CustomPaint(
          key: _surfaceKey,
          painter: rect == null
              ? null
              : TutorSpotlightPainter(
                  rect: rect.inflate(3),
                  color: context.pointyColors.warning,
                ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// Paints the ring. Public so a test can read back the rect it was given —
/// the ring being a banner's height too high is invisible to every assertion
/// that only checks a spotlight exists.
class TutorSpotlightPainter extends CustomPainter {
  const TutorSpotlightPainter({required this.rect, required this.color});

  final Rect rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(10)),
      paint,
    );
  }

  @override
  bool shouldRepaint(TutorSpotlightPainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.color != color;
}
