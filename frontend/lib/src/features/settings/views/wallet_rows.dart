import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/wallet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import 'wallet_presentation.dart';

/// One top-up: how much, when, by whom, where it stands, and whether it made
/// it into the books.
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
    final facts = <String>[
      formatDateTime(topUp.paidAt ?? topUp.createdAt),
      if (topUp.requestedBy.isNotEmpty)
        l10n.walletTopUpRequestedBy(topUp.requestedBy),
      l10n.walletTopUpInvoice(walletInvoiceText(topUp.invoiceNo)),
    ];

    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: statusColor.withValues(alpha: 0.12),
            child: Icon(
              walletTopUpStatusIcon(topUp.status),
              size: 20,
              color: statusColor,
            ),
          ),
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
                SizedBox(height: spacing.xs),
                Wrap(
                  spacing: spacing.xs,
                  runSpacing: spacing.xs,
                  children: [
                    PointyStatusPill(
                      label: walletTopUpStatusLabel(topUp.status, l10n),
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
