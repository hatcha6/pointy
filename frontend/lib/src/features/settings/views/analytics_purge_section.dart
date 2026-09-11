import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/shop_settings_view_model.dart';

/// The "clear everything" half of the telemetry page.
///
/// Telemetry is the one table that grows without anyone deciding it should — on
/// the first client's database it was 86% of a 6.4 GB dump — so a shop needs a
/// way to put it down once a copy has been taken. What a shop does not need is
/// to find out afterwards that "telemetry" also meant the activity log and the
/// audit trail, and that no backup holds a copy (the table is excluded from the
/// archive). So the dialog names all of it, and the button is the quiet kind:
/// the dialog is the gate, not the button.
///
/// Sits below the export on the same page on purpose. The only safe order is
/// take a copy, then clear, and the layout should read in that order.
class AnalyticsPurgeSection extends StatelessWidget {
  const AnalyticsPurgeSection({super.key, required this.viewModel});

  final ShopSettingsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final isPurging = viewModel.isPurgingAnalytics;

    return PointyDetailSection(
      icon: Icons.delete_forever_outlined,
      title: l10n.analyticsPurgeSectionTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.analyticsPurgeSectionDescription,
            style: theme.textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
          ),
          SizedBox(height: spacing.md),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const ValueKey('analytics_purge_button'),
              // Also disabled mid-export: clearing the table out from under a
              // running download would hand someone a half-written copy of the
              // very history they were trying to keep.
              onPressed: isPurging || viewModel.isExportingAnalytics
                  ? null
                  : () => _confirmAndPurge(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.danger,
                side: BorderSide(color: colors.danger),
              ),
              icon: isPurging
                  ? const SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_forever_outlined),
              label: Text(
                isPurging
                    ? l10n.analyticsPurgeRunningButton
                    : l10n.analyticsPurgeButton,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Ask first. There is no undo behind this and no copy in the backups, so the
  /// dialog is the only thing standing between a mis-tap and a shop's history.
  Future<void> _confirmAndPurge(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => PointyDestructiveConfirmationDialog(
        icon: Icons.delete_forever_outlined,
        title: l10n.analyticsPurgeDialogTitle,
        message: l10n.analyticsPurgeDialogMessage,
        confirmLabel: l10n.analyticsPurgeDialogConfirm,
      ),
    );
    if (confirmed != true) {
      return;
    }

    final deleted = await viewModel.purgeAnalyticsEvents();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          deleted == null
              ? l10n.analyticsPurgeFailedMessage
              : l10n.analyticsPurgeDoneMessage(deleted),
        ),
      ),
    );
  }
}
