import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../../../shared/responsive/responsive.dart';
import '../lessons/lessons.dart';
import '../models/learning_guide.dart';
import '../view_models/learning_view_model.dart';
import 'lesson_runner_screen.dart';
import 'learning_block_view.dart';
import 'learning_presentation.dart';

/// The reader: one guide rendered in full.
///
/// Pane-shaped rather than screen-shaped, so the catalogue can host it inline
/// on a wide screen and push it as a route on a phone without two layouts.
class LearningGuideView extends StatelessWidget {
  const LearningGuideView({
    super.key,
    required this.guide,
    required this.viewModel,
    this.onOpenGuide,
    this.onOpenDestination,
  });

  final LearningGuide guide;
  final LearningViewModel viewModel;

  /// Opens a cross-linked guide. Null hides the "read next" section, which is
  /// what the preview harness does.
  final ValueChanged<LearningGuide>? onOpenGuide;

  /// Opens the screen the guide teaches.
  final ValueChanged<AppNavigationDestination>? onOpenDestination;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final related = viewModel.relatedTo(guide);
    final lacksCapability =
        guide.capability != null &&
        !viewModel.capabilities.allows(guide.capability!);

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final isFinished = viewModel.isFinished(guide.id);

        return ListView(
          padding: spacing.pagePadding,
          children: [
            PointyDetailHero(
              icon: learningTrackIcon(guide.track),
              title: guide.title,
              description: guide.summary,
              pills: [
                PointyHeroPill(
                  label: learningTrackLabel(l10n, guide.track),
                  icon: learningTrackIcon(guide.track),
                ),
                PointyHeroPill(
                  label: learningKindLabel(l10n, guide.kind),
                  icon: learningKindIcon(guide.kind),
                ),
                PointyHeroPill(
                  label: learningLevelLabel(l10n, guide.level),
                  icon: Icons.stairs_outlined,
                ),
                PointyHeroPill(
                  label: l10n.learningReadingTime(guide.minutes),
                  icon: Icons.schedule_outlined,
                ),
                if (isFinished)
                  PointyHeroPill(
                    label: l10n.learningFinishedBadge,
                    icon: Icons.check_circle_outline,
                  ),
              ],
            ),
            if (lacksCapability) ...[
              SizedBox(height: spacing.md),
              PointyDetailCallout(
                icon: Icons.lock_outline,
                title: l10n.learningOutsidePermissionsNote,
                tone: PointyCalloutTone.neutral,
              ),
            ],
            for (final section in guide.sections) ...[
              SizedBox(height: spacing.md),
              PointyDetailSection(
                title: section.title,
                icon: learningKindIcon(guide.kind),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, block) in section.blocks.indexed) ...[
                      if (index > 0) SizedBox(height: spacing.md),
                      LearningBlockView(block: block),
                    ],
                  ],
                ),
              ),
            ],
            SizedBox(height: spacing.md),
            _PracticePrerequisites(guide: guide, viewModel: viewModel),
            _GuideActions(
              guide: guide,
              isFinished: isFinished,
              onToggleFinished: () => viewModel.toggleFinished(guide.id),
              onOpenDestination: onOpenDestination,
            ),
            if (related.isNotEmpty && onOpenGuide != null) ...[
              SizedBox(height: spacing.md),
              PointyDetailSection(
                title: l10n.learningRelatedTitle,
                icon: Icons.auto_stories_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in related)
                      _RelatedRow(
                        guide: entry,
                        isFinished: viewModel.isFinished(entry.id),
                        onTap: () => onOpenGuide!(entry),
                      ),
                  ],
                ),
              ),
            ],
            SizedBox(height: spacing.xl),
          ],
        );
      },
    );
  }
}

/// Names the lessons worth doing first, when the learner has not done them.
///
/// A note, not a lock: someone sent to close the register today should be able
/// to practise closing the register today. But the ordering is real — a lesson
/// that assumes an open drawer reads as broken software to someone who has
/// never opened one — so the reader says so.
class _PracticePrerequisites extends StatelessWidget {
  const _PracticePrerequisites({required this.guide, required this.viewModel});

  final LearningGuide guide;
  final LearningViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final lesson = lessonForGuide(guide.id);
    if (lesson == null) {
      return const SizedBox.shrink();
    }
    final pending = [
      for (final required in prerequisitesOf(lesson))
        if (required.guideId != null &&
            !viewModel.isFinished(required.guideId!))
          required.title,
    ];
    if (pending.isEmpty) {
      return const SizedBox.shrink();
    }
    final spacing = AdaptiveSpacing.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.only(bottom: spacing.sm),
      child: PointyDetailCallout(
        tone: PointyCalloutTone.neutral,
        icon: Icons.school_outlined,
        title: AppLocalizations.of(context)!.lessonPrerequisiteHint(
          pending.map((title) => '«$title»').join('، '),
        ),
      ),
    );
  }
}

class _GuideActions extends StatelessWidget {
  const _GuideActions({
    required this.guide,
    required this.isFinished,
    required this.onToggleFinished,
    required this.onOpenDestination,
  });

  final LearningGuide guide;
  final bool isFinished;
  final VoidCallback onToggleFinished;
  final ValueChanged<AppNavigationDestination>? onOpenDestination;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final destination = guide.opens;
    final lesson = lessonForGuide(guide.id);

    return ResponsiveActionBar(
      actions: [
        if (lesson != null)
          FilledButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => LessonRunnerScreen(lesson: lesson),
              ),
            ),
            icon: const Icon(Icons.school_outlined),
            label: Text(l10n.lessonStartButton),
          ),
        if (destination != null && onOpenDestination != null)
          FilledButton.tonalIcon(
            onPressed: () => onOpenDestination!(destination),
            icon: const Icon(Icons.open_in_new),
            label: Text(l10n.learningOpenScreenButton),
          ),
        FilledButton.icon(
          onPressed: onToggleFinished,
          icon: Icon(
            isFinished ? Icons.check_circle : Icons.check_circle_outline,
          ),
          label: Text(
            isFinished
                ? l10n.learningMarkUnfinishedButton
                : l10n.learningMarkFinishedButton,
          ),
        ),
      ],
    );
  }
}

class _RelatedRow extends StatelessWidget {
  const _RelatedRow({
    required this.guide,
    required this.isFinished,
    required this.onTap,
  });

  final LearningGuide guide;
  final bool isFinished;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        isFinished ? Icons.check_circle_outline : learningKindIcon(guide.kind),
        color: isFinished ? colors.success : colors.primaryStrong,
      ),
      title: Text(guide.title),
      subtitle: Text(
        guide.summary,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        l10n.learningReadingTime(guide.minutes),
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(color: colors.mutedInk),
      ),
      onTap: onTap,
    );
  }
}
