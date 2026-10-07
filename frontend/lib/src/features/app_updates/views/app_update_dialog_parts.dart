import 'package:flutter/material.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// The brand-teal band across the top of the dialog: an icon badge, the
/// title, and optionally the version change beneath them.
class AppUpdateHeader extends StatelessWidget {
  const AppUpdateHeader({
    super.key,
    required this.icon,
    required this.title,
    this.footer,
    this.progress,
  });

  final IconData icon;
  final String title;
  final Widget? footer;

  /// While an update runs, a ring around the badge fills with the download
  /// (spinning before the first chunk and while the installer opens).
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    // Static on purpose, like every hero: the band stays teal in dark mode.
    const onBand = PointyColors.surface;

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [PointyColors.primaryStrong, PointyColors.primaryDark],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox.square(
                  dimension: 56,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (progress case final value?)
                        Positioned.fill(
                          child: TweenAnimationBuilder<double>(
                            tween: Tween<double>(end: value),
                            duration: PointyMotion.emphasized,
                            curve: PointyMotion.curve,
                            builder: (context, animated, _) => PointySpinner(
                              value: value > 0 && value < 1 ? animated : null,
                              strokeWidth: 3,
                              color: onBand,
                              backgroundColor: onBand.withValues(alpha: 0.2),
                            ),
                          ),
                        ),
                      Container(
                        width: 46,
                        height: 46,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: onBand.withValues(alpha: 0.16),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(icon, color: onBand, size: 26),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: spacing.md),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: onBand,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            if (footer case final footer?) ...[
              SizedBox(height: spacing.md),
              footer,
            ],
          ],
        ),
      ),
    );
  }
}

/// "current → new", read in the layout's direction: in Arabic the running
/// build sits on the right and the arrow points left, to the new one.
class AppUpdateVersionTransition extends StatelessWidget {
  const AppUpdateVersionTransition({
    super.key,
    required this.currentLabel,
    required this.currentVersion,
    required this.newLabel,
    required this.newVersion,
  });

  final String currentLabel;
  final String currentVersion;
  final String newLabel;
  final String newVersion;

  @override
  Widget build(BuildContext context) {
    const onBand = PointyColors.surface;
    return Row(
      children: [
        Expanded(
          child: _VersionPill(
            label: currentLabel,
            version: currentVersion,
            emphasized: false,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          // arrow_forward mirrors itself under RTL.
          child: Icon(Icons.arrow_forward_rounded, color: onBand, size: 22),
        ),
        Expanded(
          child: _VersionPill(
            label: newLabel,
            version: newVersion,
            emphasized: true,
          ),
        ),
      ],
    );
  }
}

class _VersionPill extends StatelessWidget {
  const _VersionPill({
    required this.label,
    required this.version,
    required this.emphasized,
  });

  final String label;
  final String version;

  /// The new build: a solid white pill with teal ink, against the running
  /// build's translucent one.
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    const onBand = PointyColors.surface;
    final textTheme = Theme.of(context).textTheme;
    final ink = emphasized ? PointyColors.primaryDark : onBand;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: emphasized ? onBand : onBand.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.labelSmall?.copyWith(
                color: ink.withValues(alpha: emphasized ? 0.75 : 0.85),
              ),
            ),
            const SizedBox(height: 2),
            // Version numbers are Latin digits and dots: kept LTR so "0.7.10"
            // never renders as "10.7.0".
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(
                version.isEmpty ? '—' : version,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleMedium?.copyWith(
                  color: ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppUpdatePathStep extends StatelessWidget {
  const AppUpdatePathStep({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: colors.primaryStrong),
            const SizedBox(width: 5),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colors.primaryStrong,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
