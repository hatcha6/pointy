import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/wallet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import 'wallet_presentation.dart';

/// One top-up: how much, by which method and payer, when, by whom, where it
/// stands, and whether it made it into the books.
class WalletTopUpTile extends StatelessWidget {
  const WalletTopUpTile({super.key, required this.topUp});

  final WalletTopUp topUp;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final statusColor = walletTopUpStatusColor(topUp.status, colors);
    final method = [
      walletMethodLabel(topUp.method, l10n),
      if (topUp.transfer case final transfer?)
        ltrIsolated(LibyanIban.masked(transfer.payerIban))
      else if (topUp.payerHint.isNotEmpty)
        ltrIsolated(topUp.payerHint),
    ].join(' ');
    final facts = <String>[
      formatDateTime(topUp.paidAt ?? topUp.createdAt),
      if (topUp.method.isNotEmpty) method,
      if (topUp.requestedBy.isNotEmpty)
        l10n.walletTopUpRequestedBy(topUp.requestedBy),
      l10n.walletTopUpInvoice(walletInvoiceText(topUp.invoiceNo)),
    ];

    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          WalletMethodMark(methodKey: topUp.method, size: 36),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.walletTopUpRowTitle(formatWalletMoney(topUp.amount)),
                  style: textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: spacing.xs),
                Text(
                  facts.join(' · '),
                  style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
                // The team's reason is what the owner acts on: shown in full.
                if (topUp.status == WalletTopUpStatus.rejected &&
                    topUp.errorDetail.isNotEmpty) ...[
                  SizedBox(height: spacing.xs),
                  Text(
                    l10n.walletTransferRejectedReason(topUp.errorDetail),
                    style: textTheme.bodySmall?.copyWith(color: colors.danger),
                  ),
                ],
                SizedBox(height: spacing.xs),
                Wrap(
                  spacing: spacing.xs,
                  runSpacing: spacing.xs,
                  children: [
                    PointyStatusPill(
                      label: walletTopUpStatusLabel(topUp.status, l10n),
                      icon: walletTopUpStatusIcon(topUp.status),
                      color: statusColor,
                    ),
                    if (topUp.testMode)
                      PointyStatusPill(
                        label: l10n.walletTestModePill,
                        icon: Icons.science_outlined,
                        color: colors.warning,
                      ),
                    if (topUp.isBookedAsExpense)
                      PointyStatusPill(
                        label: l10n.walletTopUpBookedAsExpense,
                        icon: Icons.receipt_long_outlined,
                        color: colors.success,
                      )
                    else if (topUp.status == WalletTopUpStatus.paid &&
                        topUp.expenseError.isNotEmpty)
                      PointyStatusPill(
                        label: topUp.expenseError == 'period_locked'
                            ? l10n.walletTopUpExpensePeriodLocked
                            : l10n.walletTopUpExpensePending,
                        icon: Icons.info_outline,
                        color: colors.warning,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One movement of the balance, signed and coloured, with what it left.
class WalletEntryTile extends StatelessWidget {
  const WalletEntryTile({super.key, required this.entry});

  final WalletEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final credit = entry.amount >= 0;
    final amountColor = credit ? colors.success : colors.danger;
    final service = walletServiceLabel(entry.service, l10n);
    final title = service == null
        ? walletEntryKindLabel(entry.kind, l10n)
        : '${walletEntryKindLabel(entry.kind, l10n)} · $service';
    final signed =
        '${credit ? '+' : '−'}${formatWalletMoney(entry.amount.abs())}';

    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: amountColor.withValues(alpha: 0.12),
            child: Icon(
              walletEntryKindIcon(entry.kind),
              size: 20,
              color: amountColor,
            ),
          ),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (entry.description.isNotEmpty) ...[
                  SizedBox(height: spacing.xs),
                  Text(
                    entry.description,
                    style: textTheme.bodySmall?.copyWith(color: colors.ink),
                  ),
                ],
                SizedBox(height: spacing.xs),
                Text(
                  [
                    formatDateTime(entry.createdAt),
                    l10n.walletEntryBalanceAfter(
                      formatWalletMoney(entry.balanceAfter),
                    ),
                  ].join(' · '),
                  style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              ],
            ),
          ),
          SizedBox(width: spacing.sm),
          Text(
            signed,
            style: PointyTypography.numeric(
              (textTheme.titleSmall ?? const TextStyle()).copyWith(
                color: amountColor,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One balance as a line in a transfer sheet: its mark and what it holds.
class WalletBalanceLine extends StatelessWidget {
  const WalletBalanceLine({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: colors.mutedInk),
        SizedBox(width: spacing.xs),
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
