import 'package:flutter/material.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../models/learning_guide.dart';

/// Renders one [LearningBlock].
///
/// A closed `switch` over the sealed block type: adding a block kind is a
/// compile error here until it is drawn, which is what keeps content and
/// rendering from drifting apart.
class LearningBlockView extends StatelessWidget {
  const LearningBlockView({super.key, required this.block});

  final LearningBlock block;

  @override
  Widget build(BuildContext context) {
    return switch (block) {
      LearningParagraph(:final text) => _Paragraph(text: text),
      LearningSteps(:final steps) => _Steps(steps: steps),
      LearningBullets(:final items) => _Bullets(items: items),
      LearningDefinitions(:final entries) => _Definitions(entries: entries),
      LearningNote(:final tone, :final title, :final message) => _Note(
        tone: tone,
        title: title,
        message: message,
      ),
    };
  }
}

class _Paragraph extends StatelessWidget {
  const _Paragraph({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      // Guide prose is read, not scanned: a little extra leading is the
      // difference between a paragraph and a wall of Arabic.
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.7),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.steps});

  final List<LearningStep> steps;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, step) in steps.indexed) ...[
          if (index > 0) SizedBox(height: spacing.md),
          _Step(number: index + 1, step: step),
        ],
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.step});

  final int number;
  final LearningStep step;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              colors.primaryStrong.withValues(alpha: 0.12),
              colors.surface,
            ),
            shape: BoxShape.circle,
          ),
          child: Text(
            '$number',
            style: textTheme.labelLarge?.copyWith(
              color: colors.primaryDark,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                step.text,
                style: textTheme.bodyLarge?.copyWith(
                  height: 1.6,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (step.detail case final detail?) ...[
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: textTheme.bodyMedium?.copyWith(
                    color: colors.mutedInk,
                    height: 1.6,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Bullets extends StatelessWidget {
  const _Bullets({required this.items});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, item) in items.indexed) ...[
          if (index > 0) const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(top: 8),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: colors.primaryStrong,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item,
                  style: textTheme.bodyLarge?.copyWith(height: 1.6),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Definitions extends StatelessWidget {
  const _Definitions({required this.entries});

  final List<LearningDefinition> entries;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: Border.all(color: colors.line),
      ),
      // Stretch, not the default centre: a Column centres children at their
      // intrinsic width, so a row with a short meaning sat inset from both
      // edges while a long one filled — and no two terms started at the same
      // place down the list.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, entry) in entries.indexed) ...[
            if (index > 0)
              Divider(height: 1, indent: 14, endIndent: 14, color: colors.line),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.term,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colors.primaryDark,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.meaning,
                    style: textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.tone, required this.title, this.message});

  final LearningNoteTone tone;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return PointyDetailCallout(
      icon: switch (tone) {
        LearningNoteTone.tip => Icons.lightbulb_outline,
        LearningNoteTone.warning => Icons.warning_amber_outlined,
        LearningNoteTone.danger => Icons.report_gmailerrorred_outlined,
        LearningNoteTone.info => Icons.info_outline,
      },
      title: title,
      message: message,
      tone: switch (tone) {
        LearningNoteTone.tip => PointyCalloutTone.success,
        LearningNoteTone.warning => PointyCalloutTone.warning,
        LearningNoteTone.danger => PointyCalloutTone.danger,
        LearningNoteTone.info => PointyCalloutTone.primary,
      },
    );
  }
}
