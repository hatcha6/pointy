import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

/// A translucent pill rendered inside [PointyDetailHero] on the dark gradient
/// surface (white text on a low-alpha fill).
class PointyHeroPill {
  const PointyHeroPill({required this.label, this.icon});

  final String label;
  final IconData? icon;
}

/// The canonical gradient header for entity-detail screens.
///
/// Mirrors the discount-details hero: a teal gradient surface carrying a
/// circular icon badge, a [title], an optional headline [value] (with an
/// optional [valueSubtitle] sitting beside it), an optional [description], and
/// a wrap of translucent [pills]. Using this everywhere keeps customer,
/// supplier, product, payroll and discount detail pages visually in lockstep.
class PointyDetailHero extends StatelessWidget {
  const PointyDetailHero({
    super.key,
    required this.icon,
    required this.title,
    this.value,
    this.valueSubtitle,
    this.description,
    this.pills = const [],
    this.gradientColors,
  });

  /// Icon shown in the circular badge next to the [title].
  final IconData icon;

  /// Primary heading — usually the entity name.
  final String title;

  /// Optional large headline figure (e.g. a lifetime total or unit price).
  final String? value;

  /// Optional supporting text rendered next to [value]. Ignored when [value]
  /// is null.
  final String? valueSubtitle;

  /// Optional longer description paragraph.
  final String? description;

  /// Status / metadata pills rendered below the headline.
  final List<PointyHeroPill> pills;

  /// Optional gradient override. Defaults to the brand teal gradient.
  final List<Color>? gradientColors;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    const onPrimary = PointyColors.surface;
    final gradient =
        gradientColors ??
        const [PointyColors.primaryStrong, PointyColors.primaryDark];

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: gradient,
        ),
        borderRadius: BorderRadius.circular(PointyRadii.card),
        boxShadow: PointyShadows.raised,
      ),
      padding: EdgeInsets.all(spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: onPrimary.withOpacity(0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: onPrimary),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleLarge?.copyWith(
                    color: onPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          if (value case final headline?) ...[
            SizedBox(height: spacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  child: Text(
                    headline,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.displaySmall?.copyWith(
                      color: onPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (valueSubtitle case final subtitle?) ...[
                  SizedBox(width: spacing.sm),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(bottom: 6),
                      child: Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          color: onPrimary.withOpacity(0.85),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
          if (description != null && description!.trim().isNotEmpty) ...[
            SizedBox(height: spacing.sm),
            Text(
              description!.trim(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyMedium?.copyWith(
                color: onPrimary.withOpacity(0.85),
              ),
            ),
          ],
          if (pills.isNotEmpty) ...[
            SizedBox(height: spacing.md),
            Wrap(
              spacing: spacing.xs,
              runSpacing: spacing.xs,
              children: [for (final pill in pills) _HeroPill(pill: pill)],
            ),
          ],
        ],
      ),
    );
  }
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.pill});

  final PointyHeroPill pill;

  @override
  Widget build(BuildContext context) {
    const onPrimary = PointyColors.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: onPrimary.withOpacity(0.16),
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pill.icon case final icon?) ...[
              Icon(icon, size: 15, color: onPrimary),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                pill.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: onPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
