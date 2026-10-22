import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';
import 'pointy_progress.dart';

/// Where a transaction shown in a [PointyResultPanel] stands.
enum PointyResultTone {
  /// Still being done. Nothing may close the panel.
  working,
  success,

  /// Done, but something in it needs the person's attention.
  attention,
  failure,
}

/// Opens the dialog a transaction runs in: its progress first, then — in the
/// same dialog, without a flash between them — what came of it.
///
/// Built for the moment after a confirm button, where the old way was a
/// spinner on that button, then a snackbar that scrolled away with whatever
/// mattered in it. The dialog decides for itself when it may be closed (see
/// [PopScope] in its content); the barrier only asks.
///
/// [maxWidth] is the widest any of its stages may grow; each stage can keep
/// itself narrower.
Future<T?> showPointyResultDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxWidth = 520,
}) {
  return showDialog<T>(
    context: context,
    builder: (dialogContext) {
      final width = MediaQuery.sizeOf(dialogContext).width;
      final narrow = width < AppBreakpoints.tabletMin;
      return Dialog(
        insetPadding: EdgeInsets.symmetric(
          horizontal: narrow ? 12 : 40,
          vertical: narrow ? 16 : 24,
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: builder(dialogContext),
        ),
      );
    },
  );
}

/// The one layout every transaction result shares: a status mark, what
/// happened, the figure that matters most, the details, and what to do next.
///
/// Switching [tone] from working to a result animates the mark in place and
/// lets the panel grow to its new content, so progress turning into an outcome
/// reads as one thing happening rather than one dialog replacing another.
class PointyResultPanel extends StatelessWidget {
  const PointyResultPanel({
    super.key,
    required this.tone,
    required this.title,
    this.subtitle,
    this.headline,
    this.children = const [],
    this.footer,
    this.showMark = true,
  });

  final PointyResultTone tone;
  final String title;
  final String? subtitle;

  /// The figure the person acts on first — the change to count out.
  final Widget? headline;
  final List<Widget> children;

  /// The actions, pinned below the scrolling details.
  final Widget? footer;

  /// False for a stage that is a form rather than an outcome — the space the
  /// mark would take goes to the fields.
  final bool showMark;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final spacing = AdaptiveSpacing.of(context);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    final header = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showMark) ...[
          PointyResultMark(tone: tone),
          SizedBox(height: spacing.sm),
        ],
        Semantics(
          liveRegion: true,
          header: true,
          child: Text(
            title,
            key: const ValueKey('result_panel_title'),
            textAlign: TextAlign.center,
            style: textTheme.titleLarge?.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (subtitle case final subtitle? when subtitle.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            key: const ValueKey('result_panel_subtitle'),
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(
              color: colors.mutedInk,
              height: 1.4,
            ),
          ),
        ],
        if (headline != null) ...[SizedBox(height: spacing.sm), headline!],
      ],
    );

    return AnimatedSize(
      duration: reduceMotion ? Duration.zero : PointyMotion.emphasized,
      curve: PointyMotion.emphasizedCurve,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                spacing.lg,
                spacing.lg,
                spacing.lg,
                spacing.md,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  for (final child in children) ...[
                    SizedBox(height: spacing.md),
                    child,
                  ],
                ],
              ),
            ),
          ),
          if (footer != null)
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.line)),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  spacing.lg,
                  spacing.sm,
                  spacing.lg,
                  spacing.md,
                ),
                child: footer,
              ),
            ),
        ],
      ),
    );
  }
}

/// The round status mark at the top of a [PointyResultPanel]: a spinner while
/// [PointyResultTone.working], then the outcome's icon popping in where the
/// spinner was.
class PointyResultMark extends StatelessWidget {
  const PointyResultMark({super.key, required this.tone, this.size = 64});

  final PointyResultTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final (Color accent, IconData? icon) = switch (tone) {
      PointyResultTone.working => (colors.primaryStrong, null),
      PointyResultTone.success => (colors.success, Icons.check_rounded),
      PointyResultTone.attention => (
        colors.warning,
        Icons.priority_high_rounded,
      ),
      PointyResultTone.failure => (colors.danger, Icons.close_rounded),
    };

    final mark = Container(
      key: ValueKey('result_mark_${tone.name}'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Color.alphaBlend(accent.withValues(alpha: 0.14), colors.surface),
      ),
      alignment: Alignment.center,
      child: icon == null
          ? SizedBox.square(
              dimension: size * 0.56,
              child: PointySpinner(strokeWidth: 3.5, color: accent),
            )
          // Pops in where the spinner was, so the outcome lands as an event
          // even when the dialog's whole content was swapped beneath it.
          : TweenAnimationBuilder<double>(
              tween: Tween(begin: reduceMotion ? 1 : 0.4, end: 1),
              duration: reduceMotion
                  ? Duration.zero
                  : PointyMotion.emphasized * 2,
              curve: Curves.easeOutBack,
              builder: (context, scale, child) =>
                  Transform.scale(scale: scale, child: child),
              child: Icon(icon, size: size * 0.58, color: accent),
            ),
    );

    return AnimatedSwitcher(
      duration: reduceMotion ? Duration.zero : PointyMotion.emphasized,
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: animation, child: child),
      ),
      child: mark,
    );
  }
}

/// The one figure a result is read for, large — the change to count out, the
/// order's total.
class PointyResultFigure extends StatelessWidget {
  const PointyResultFigure({
    super.key,
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;

  /// Already formatted: money, a count, whatever the figure is.
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.pointyColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: 0.10), colors.surface),
        borderRadius: BorderRadius.circular(PointyRadii.input),
      ),
      child: Column(
        children: [
          Text(label, style: textTheme.labelLarge?.copyWith(color: color)),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: PointyTypography.numeric(
                (textTheme.displaySmall ?? const TextStyle()).copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small titled block inside a result — "what you can do", the cards' PINs.
class PointyResultSection extends StatelessWidget {
  const PointyResultSection({
    super.key,
    required this.title,
    required this.child,
    this.icon,
  });

  final String title;
  final IconData? icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: colors.mutedInk),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                title,
                style: textTheme.titleSmall?.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

/// A row of bulleted advice lines.
class PointyResultTips extends StatelessWidget {
  const PointyResultTips({super.key, required this.tips});

  final List<String> tips;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final tip in tips)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Icon(Icons.circle, size: 6, color: colors.mutedInk),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tip,
                    style: textTheme.bodyMedium?.copyWith(
                      color: colors.ink,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
