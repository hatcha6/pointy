import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/wallet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/wallet_view_model.dart';
import 'wallet_history_page.dart';
import 'wallet_presentation.dart';
import 'wallet_rows.dart';
import 'wallet_top_up_sheet.dart';

/// The Daftar wallet on the subscription page: the balance, the top-up button,
/// the switch that puts top-ups in the shop's books, and the latest top-ups.
class WalletSection extends StatelessWidget {
  const WalletSection({super.key, required this.viewModel});

  final WalletViewModel viewModel;

  static const _recentShown = 3;

  Future<void> _openHistory(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WalletHistoryPage(viewModel: viewModel),
      ),
    );
  }

  Future<void> _setRecordExpenses(BuildContext context, bool value) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    final ok = await viewModel.setRecordTopUpsAsExpenses(value);
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.walletSettingsSaveFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final colors = context.pointyColors;
        final overview = viewModel.overview;
        return PointyDetailSection(
          icon: Icons.account_balance_wallet_outlined,
          title: l10n.walletSectionTitle,
          trailing: (overview?.testMode ?? false)
              ? PointyStatusPill(
                  label: l10n.walletTestModePill,
                  icon: Icons.science_outlined,
                  color: colors.warning,
                )
              : null,
          child: _body(context, l10n, overview),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    WalletOverview? overview,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    if (overview == null) {
      if (viewModel.isLoading || !viewModel.hasLoadError) {
        return Padding(
          padding: EdgeInsets.symmetric(vertical: spacing.lg),
          child: const Center(
            child: SizedBox.square(dimension: 28, child: PointySpinner()),
          ),
        );
      }
      return PointyDetailCallout(
        icon: Icons.cloud_off_outlined,
        tone: PointyCalloutTone.danger,
        title: l10n.walletLoadError,
        trailing: TextButton(
          onPressed: viewModel.load,
          child: Text(l10n.retryButton),
        ),
      );
    }

    final balance = overview.balance;
    final recent = overview.recentTopUps.take(_recentShown).toList();
    final error = overview.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.walletBalanceLabel,
          style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
        SizedBox(height: spacing.xs),
        Text(
          balance == null ? '—' : formatWalletMoney(balance),
          style: PointyTypography.numeric(
            (textTheme.headlineMedium ?? const TextStyle()).copyWith(
              fontWeight: FontWeight.w800,
              color: colors.ink,
            ),
          ),
        ),
        SizedBox(height: spacing.xs),
        Text(
          l10n.walletExplainer,
          style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
        SizedBox(height: spacing.md),
        if (!overview.available && error != null) ...[
          PointyDetailCallout(
            icon: Icons.cloud_off_outlined,
            tone: PointyCalloutTone.warning,
            title: l10n.walletUnavailableTitle,
            message: walletErrorMessage(
              l10n,
              code: error.code,
              message: error.message,
            ),
            trailing: TextButton(
              onPressed: viewModel.load,
              child: Text(l10n.retryButton),
            ),
          ),
          SizedBox(height: spacing.md),
        ] else if (!overview.canTopUp) ...[
          PointyInlineMessage(
            message: l10n.walletTopUpsUnavailable,
            compact: true,
          ),
          SizedBox(height: spacing.sm),
        ],
        if (overview.testMode) ...[
          PointyInlineMessage.warning(
            message: l10n.walletTestModeHint,
            compact: true,
          ),
          SizedBox(height: spacing.sm),
        ],
        Wrap(
          spacing: spacing.sm,
          runSpacing: spacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: overview.canTopUp
                  ? () => showWalletTopUpSheet(
                      context: context,
                      viewModel: viewModel,
                    )
                  : null,
              icon: const Icon(Icons.add_card_outlined),
              label: Text(l10n.walletTopUpButton),
            ),
            TextButton.icon(
              onPressed: overview.available
                  ? () => _openHistory(context)
                  : null,
              icon: const Icon(Icons.history),
              label: Text(l10n.walletViewHistory),
            ),
          ],
        ),
        SizedBox(height: spacing.sm),
        const Divider(height: 1),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          value: viewModel.recordTopUpsAsExpenses,
          onChanged: viewModel.isSavingSettings
              ? null
              : (value) => _setRecordExpenses(context, value),
          title: Text(l10n.walletRecordExpensesTitle),
          subtitle: Text(
            l10n.walletRecordExpensesSubtitle(
              overview.settings.effectiveCategoryName,
            ),
          ),
        ),
        const Divider(height: 1),
        SizedBox(height: spacing.sm),
        Text(l10n.walletRecentTopUpsTitle, style: textTheme.titleSmall),
        if (recent.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: spacing.sm),
            child: Text(
              l10n.walletNoTopUps,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          )
        else
          for (final topUp in recent) WalletTopUpTile(topUp: topUp),
      ],
    );
  }
}
