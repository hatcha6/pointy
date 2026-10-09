import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../shared/design/design.dart';
import '../../../../shared/responsive/responsive.dart';

/// What happens after the cashier chooses, in four short steps that read in
/// the order of the paper: اختر ← أضف إلى السلة ← أصدر الفاتورة ← يصل المبلغ
/// ويُطبع الإيصال. Always the same four, for every service, so it is learned
/// once.
class ServiceTimeline extends StatelessWidget {
  const ServiceTimeline({
    super.key,
    this.compact = false,
    this.singleLine = false,
  });

  /// Smaller type and no icons, for a footer.
  final bool compact;

  /// One row that never wraps: put it in a `FittedBox` to scale it to fit.
  final bool singleLine;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final steps = [
      (Icons.touch_app_rounded, l10n.posServicesTimelineChoose),
      (Icons.add_shopping_cart_rounded, l10n.posServicesTimelineCart),
      (Icons.receipt_long_rounded, l10n.posServicesTimelineInvoice),
      (Icons.bolt_rounded, l10n.posServicesTimelineDone),
    ];
    final items = [
      for (final (index, (icon, label)) in steps.indexed) ...[
        if (index > 0)
          Icon(
            Icons.chevron_right_rounded,
            size: compact ? 16 : 18,
            color: colors.mutedInk,
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!compact) ...[
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.primaryContainer,
                ),
                child: Icon(icon, size: 13, color: colors.primaryStrong),
              ),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: (compact ? textTheme.labelSmall : textTheme.labelMedium)
                  ?.copyWith(color: colors.ink, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ],
    ];
    if (singleLine) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, item) in items.indexed) ...[
            if (index > 0) SizedBox(width: compact ? 4 : 6),
            item,
          ],
        ],
      );
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: compact ? 4 : 6,
      runSpacing: 4,
      children: items,
    );
  }
}

/// The banner that explains a service the first time it is opened: one line
/// of what it does, the four steps, a «كيف يعمل؟» button and a way to hide it
/// for good. A help button on the pane brings it back.
class ServiceExplainerBanner extends StatelessWidget {
  const ServiceExplainerBanner({
    super.key,
    required this.icon,
    required this.body,
    required this.onHow,
    required this.onDismiss,
  });

  final IconData icon;
  final String body;
  final VoidCallback onHow;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final spacing = AdaptiveSpacing.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(PointyRadii.card + 2),
        border: Border.all(color: colors.primaryStrong.withValues(alpha: 0.22)),
      ),
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          spacing.sm + 2,
          spacing.sm,
          spacing.xs,
          spacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.primaryStrong,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.white, size: 21),
            ),
            SizedBox(width: spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    body,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w700,
                      height: 1.4,
                    ),
                  ),
                  TextButton.icon(
                    key: const ValueKey('service_explainer_how'),
                    onPressed: onHow,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.help_outline_rounded, size: 17),
                    label: Text(l10n.posServicesHow),
                  ),
                ],
              ),
            ),
            IconButton(
              key: const ValueKey('service_explainer_dismiss'),
              tooltip: l10n.posServicesExplainerHide,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: EdgeInsets.zero,
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded, size: 19),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the «كيف يعمل؟» sheet says: three steps, each with a picture, then
/// the plain facts a customer should be told.
class ServiceHowStep {
  const ServiceHowStep({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;
}

class ServiceHowSheet extends StatelessWidget {
  const ServiceHowSheet({
    super.key,
    required this.title,
    required this.steps,
    required this.facts,
    this.timeline = false,
  });

  final String title;
  final List<ServiceHowStep> steps;

  /// Also draw the four steps that follow the choice.
  final bool timeline;

  /// Plain statements of what is not possible: no refund, countries not served.
  final List<String> facts;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final spacing = AdaptiveSpacing.of(context);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(spacing.lg, 0, spacing.lg, spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: textTheme.titleLarge?.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: spacing.md),
            for (final (index, step) in steps.indexed) ...[
              if (index > 0) SizedBox(height: spacing.sm),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      step.icon,
                      color: colors.primaryStrong,
                      size: 26,
                    ),
                  ),
                  SizedBox(width: spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${index + 1}. ${step.title}',
                          style: textTheme.titleSmall?.copyWith(
                            color: colors.ink,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          step.body,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colors.mutedInk,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
            if (timeline) ...[
              SizedBox(height: spacing.md),
              Text(
                l10n.posServicesTimelineTitle,
                style: textTheme.titleSmall?.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              const ServiceTimeline(),
            ],
            SizedBox(height: spacing.md),
            for (final fact in facts) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color: colors.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        fact,
                        style: textTheme.bodyMedium?.copyWith(
                          color: colors.ink,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            SizedBox(height: spacing.sm),
            FilledButton(
              key: const ValueKey('service_how_done'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.posServicesHowDone),
            ),
          ],
        ),
      ),
    );
  }
}
