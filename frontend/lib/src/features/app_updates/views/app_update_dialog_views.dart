import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/app_update_prompter.dart';
import 'app_update_dialog_parts.dart';
import 'app_update_progress.dart';

/// The offer, in whichever state the dialog is in: asking, downloading
/// ([installing], with [progress]), or after a [failed] attempt. Pure, so the
/// preview harness can show each state without driving a download.
class AppUpdateOfferView extends StatelessWidget {
  const AppUpdateOfferView({
    super.key,
    required this.offer,
    required this.installing,
    required this.failed,
    required this.progress,
    required this.onUpdate,
    required this.onLater,
  });

  final AppUpdateOffer offer;
  final bool installing;
  final bool failed;
  final double progress;
  final VoidCallback onUpdate;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final spacing = AdaptiveSpacing.of(context);
    final size = offer.release.size;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppUpdateHeader(
          icon: Icons.system_update_alt_rounded,
          title: l10n.appUpdatePromptTitle,
          progress: installing ? progress : null,
          footer: AppUpdateVersionTransition(
            currentLabel: l10n.appUpdatesCurrentVersionLabel,
            currentVersion: offer.currentVersion,
            newLabel: l10n.appUpdatePromptNewVersionLabel,
            newVersion: offer.release.version,
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              spacing.lg,
              spacing.lg,
              spacing.lg,
              spacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.appUpdatePromptMessage, style: textTheme.bodyLarge),
                if (installing) ...[
                  SizedBox(height: spacing.md),
                  AppUpdateProgress(progress: progress, totalBytes: size),
                ] else if (size != null && size > 0) ...[
                  SizedBox(height: spacing.sm),
                  Row(
                    children: [
                      Icon(
                        Icons.download_outlined,
                        size: 18,
                        color: colors.mutedInk,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          l10n.appUpdatePromptDownloadSize(
                            appUpdateMegabytes(size),
                          ),
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (failed) ...[
                  SizedBox(height: spacing.md),
                  PointyInlineMessage.error(message: l10n.appUpdatesFailed),
                ],
              ],
            ),
          ),
        ),
        // Nothing to press while it runs: the progress is the whole story,
        // and "later" halfway through a download would only waste it.
        if (installing)
          SizedBox(height: spacing.md)
        else
          Padding(
            padding: EdgeInsets.fromLTRB(
              spacing.lg,
              spacing.sm,
              spacing.lg,
              spacing.lg,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: onLater,
                    child: Text(l10n.appUpdatePromptLater),
                  ),
                ),
                SizedBox(width: spacing.sm),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: onUpdate,
                    icon: Icon(
                      failed ? Icons.refresh_rounded : Icons.download_rounded,
                    ),
                    label: Text(
                      failed ? l10n.retryButton : l10n.appUpdatesInstall,
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

/// What "later" turns the dialog into: where the update can be found again.
class AppUpdateReminderView extends StatelessWidget {
  const AppUpdateReminderView({
    super.key,
    required this.version,
    required this.onDismiss,
  });

  final String version;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppUpdateHeader(
          icon: Icons.bookmark_added_outlined,
          title: l10n.appUpdateReminderTitle,
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            spacing.lg,
            spacing.lg,
            spacing.lg,
            spacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.appUpdateReminderMessage(version),
                style: textTheme.bodyLarge,
              ),
              SizedBox(height: spacing.md),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: spacing.xs,
                runSpacing: spacing.xs,
                children: [
                  AppUpdatePathStep(
                    icon: Icons.settings_outlined,
                    label: l10n.deviceSettingsTitle,
                  ),
                  PointyDisclosureChevron(
                    size: 20,
                    color: context.pointyColors.mutedInk,
                  ),
                  AppUpdatePathStep(
                    icon: Icons.system_update_outlined,
                    label: l10n.clientUpdatesTitle,
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            spacing.lg,
            spacing.sm,
            spacing.lg,
            spacing.lg,
          ),
          child: FilledButton(
            onPressed: onDismiss,
            child: Text(l10n.appUpdateReminderDismiss),
          ),
        ),
      ],
    );
  }
}
