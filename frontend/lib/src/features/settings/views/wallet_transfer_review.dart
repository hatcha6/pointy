import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/wallet_view_model.dart';
import 'wallet_presentation.dart';

/// After the receipt went up: the team is checking the transfer. The sheet
/// keeps asking and turns into the verdict by itself, but nothing is lost by
/// closing it — the owner is told the outcome in the notifications, and the
/// wallet shows it.
class WalletTransferReview extends StatelessWidget {
  const WalletTransferReview({
    super.key,
    required this.viewModel,
    required this.onClose,
  });

  final WalletViewModel viewModel;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final topUp = viewModel.activeTopUp;

    return SingleChildScrollView(
      padding: EdgeInsets.all(spacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            Icons.mark_email_read_outlined,
            size: 56,
            color: colors.primaryStrong,
          ),
          SizedBox(height: spacing.sm),
          Text(
            l10n.walletTransferReviewTitle,
            textAlign: TextAlign.center,
            style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          SizedBox(height: spacing.sm),
          Text(
            l10n.walletTransferReviewBody,
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium,
          ),
          SizedBox(height: spacing.md),
          if (topUp != null)
            Text(
              formatWalletMoney(topUp.amount),
              textAlign: TextAlign.center,
              style: PointyTypography.numeric(
                (textTheme.headlineSmall ?? const TextStyle()).copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          if (topUp != null && topUp.invoiceNo.isNotEmpty)
            SelectableText(
              l10n.walletTopUpInvoice(walletInvoiceText(topUp.invoiceNo)),
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          SizedBox(height: spacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox.square(
                dimension: 16,
                child: PointySpinner(strokeWidth: 2),
              ),
              SizedBox(width: spacing.xs),
              Text(
                l10n.walletTransferReviewWaiting,
                style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
              ),
            ],
          ),
          if (topUp?.testMode ?? false) ...[
            SizedBox(height: spacing.sm),
            Center(
              child: PointyStatusPill(
                label: l10n.walletTestModePill,
                icon: Icons.science_outlined,
                color: colors.warning,
              ),
            ),
          ],
          SizedBox(height: spacing.md),
          FilledButton(onPressed: onClose, child: Text(l10n.walletClose)),
        ],
      ),
    );
  }
}
