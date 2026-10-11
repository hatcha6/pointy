import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import 'wallet_presentation.dart';

/// What a gateway top-up puts in the wallet, shown on the form before the
/// owner pays: what they pay, the gateway fee kept out of it, and what the
/// wallet gets. Before an amount is typed it says that a fee applies.
class WalletFeeBreakdown extends StatelessWidget {
  const WalletFeeBreakdown({
    super.key,
    required this.percent,
    required this.amount,
    required this.fee,
    this.transferIsFree = false,
  });

  final double percent;

  /// What the payer pays; null while no valid amount is typed.
  final double? amount;
  final double fee;

  /// A bank transfer is offered and costs nothing: worth a word.
  final bool transferIsFree;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final percentText = formatWalletPercent(percent);
    final amount = this.amount;
    final noteStyle = textTheme.bodySmall?.copyWith(color: colors.mutedInk);

    return Container(
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          colors.primaryStrong.withValues(alpha: 0.06),
          colors.surface,
        ),
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        border: Border.all(color: colors.primaryStrong.withValues(alpha: 0.18)),
      ),
      padding: EdgeInsets.all(spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.receipt_long_outlined,
                size: 18,
                color: colors.primaryStrong,
              ),
              SizedBox(width: spacing.xs),
              Expanded(
                child: Text(
                  l10n.walletFeeTitle,
                  style: textTheme.titleSmall?.copyWith(
                    color: colors.primaryDark,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.sm),
          if (amount == null)
            Text(l10n.walletFeeEmptyHint(percentText), style: noteStyle)
          else ...[
            PointySummaryList(
              rows: [
                PointySummaryRow(
                  label: l10n.walletFeePaidLabel,
                  value: formatWalletMoney(amount),
                ),
                PointySummaryRow(
                  label: l10n.walletFeeLabel(percentText),
                  value: formatWalletDeduction(fee),
                  valueColor: colors.danger,
                ),
                PointySummaryRow(
                  label: l10n.walletFeeCreditLabel,
                  value: formatWalletMoney(amount - fee),
                  valueColor: colors.success,
                  emphasized: true,
                  dividerAbove: true,
                ),
              ],
            ),
            SizedBox(height: spacing.sm),
            Text(l10n.walletFeeNote(percentText), style: noteStyle),
          ],
          if (transferIsFree) ...[
            SizedBox(height: spacing.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lightbulb_outline, size: 16, color: colors.mutedInk),
                SizedBox(width: spacing.xs),
                Expanded(
                  child: Text(l10n.walletFeeTransferTip, style: noteStyle),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
