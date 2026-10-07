import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// How far an app update has got, for whoever is waiting on it.
///
/// One panel for the update dialog and the device-settings updates page: a big
/// percentage, megabytes so far against the whole, a bar that glides between
/// chunks instead of jumping, and a line saying what happens next. The three
/// phases read differently — starting (nothing received yet), downloading,
/// and handing over to the installer once the last byte is in — so a slow
/// shop line never looks like a stuck one.
class AppUpdateProgress extends StatelessWidget {
  const AppUpdateProgress({super.key, required this.progress, this.totalBytes});

  /// 0..1 of the download. 0 before the first chunk; 1 once it is all in.
  final double progress;

  /// The installer's size, when the manifest gave it.
  final int? totalBytes;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final spacing = AdaptiveSpacing.of(context);
    final value = progress.clamp(0.0, 1.0);
    final started = value > 0;
    final downloading = started && value < 1;
    final finished = value >= 1;
    final total = totalBytes;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.subtleFill,
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Nothing to count until the first chunk lands: a "0%" over a
            // spinning bar reads as stuck rather than starting.
            if (started) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    l10n.appUpdateProgressPercent((value * 100).floor()),
                    style: textTheme.headlineSmall?.copyWith(
                      color: colors.primaryStrong,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(width: spacing.sm),
                  Expanded(
                    child: total != null && total > 0
                        ? Text(
                            l10n.appUpdateProgressMegabytes(
                              appUpdateMegabytes((total * value).round()),
                              appUpdateMegabytes(total),
                            ),
                            textAlign: TextAlign.end,
                            style: textTheme.bodySmall?.copyWith(
                              color: colors.mutedInk,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
              SizedBox(height: spacing.sm),
            ],
            // Chunks land in bursts; easing between them keeps the bar
            // moving like a download rather than ticking like a counter.
            TweenAnimationBuilder<double>(
              tween: Tween<double>(end: value),
              duration: PointyMotion.emphasized,
              curve: PointyMotion.curve,
              builder: (context, animated, _) => PointyProgressBar(
                value: started ? animated : null,
                minHeight: 10,
                color: colors.primary,
                backgroundColor: colors.line,
                borderRadius: BorderRadius.circular(PointyRadii.pill),
              ),
            ),
            SizedBox(height: spacing.sm),
            Row(
              children: [
                Icon(
                  finished
                      ? Icons.install_mobile_outlined
                      : Icons.cloud_download_outlined,
                  size: 18,
                  color: colors.mutedInk,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    finished
                        ? l10n.appUpdateProgressInstalling
                        : downloading
                        ? l10n.appUpdateProgressDownloading
                        : l10n.appUpdateProgressStarting,
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: spacing.xs),
            Text(
              l10n.appUpdatePromptInstallHint,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ],
        ),
      ),
    );
  }
}

/// An installer's size in megabytes: whole past ten, one decimal below
/// ("79", "8.4").
String appUpdateMegabytes(int bytes) {
  if (bytes <= 0) return '0';
  final value = bytes / (1024 * 1024);
  return value >= 10 ? value.round().toString() : value.toStringAsFixed(1);
}
