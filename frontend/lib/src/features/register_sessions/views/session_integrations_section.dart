import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/integration_provider.dart';
import '../../../data/models/register_session_summary.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../settings/views/integration_presentation.dart';

/// Where the shift's provider money went: what customers paid for each
/// provider's top-ups and cards, how much of that is the provider's, and what
/// the shop keeps.
///
/// A drawer that counts right can still hide a shift that went wrong here. A
/// renewal the customer paid for and the provider never performed sits in the
/// drawer looking like takings; a sale refunded after the provider performed it
/// balances the drawer while the agency float paid for nothing. So the happy
/// path stays quiet — one green pill — and every way the money can go astray
/// gets a sentence of its own.
class SessionIntegrationsSection extends StatelessWidget {
  const SessionIntegrationsSection({
    super.key,
    required this.integrations,
    this.onOpenOrder,
  });

  final SessionIntegrations integrations;

  /// Opens the sale a transaction was rung up on.
  final ValueChanged<SessionIntegrationTransaction>? onOpenOrder;

  @override
  Widget build(BuildContext context) {
    if (!integrations.hasActivity) {
      // A shop that resells nothing sees no section, not a row of zeroes.
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final providers = integrations.providers;

    return PointyDetailSection(
      title: l10n.sessionIntegrationsTitle,
      icon: Icons.sim_card_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, figures) in providers.indexed) ...[
            if (index > 0) const Divider(height: 32),
            _ProviderBreakdown(
              key: ValueKey('session_integrations_${figures.provider}'),
              figures: figures,
              transactions: integrations.transactionsFor(figures.provider),
              onOpenOrder: onOpenOrder,
            ),
          ],
          if (providers.length > 1) ...[
            const Divider(height: 32),
            Text(
              l10n.sessionIntegrationsTotalsTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            _MoneySplit(figures: integrations.totals),
          ],
        ],
      ),
    );
  }
}

class _ProviderBreakdown extends StatelessWidget {
  const _ProviderBreakdown({
    super.key,
    required this.figures,
    required this.transactions,
    required this.onOpenOrder,
  });

  final SessionIntegrationFigures figures;
  final List<SessionIntegrationTransaction> transactions;
  final ValueChanged<SessionIntegrationTransaction>? onOpenOrder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final key = integrationProviderKeyFromJson(figures.provider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IntegrationProviderLogo(providerKey: key, size: 28),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                integrationProviderName(key, l10n),
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              l10n.sessionPaymentOperationsCount(figures.transactionCount),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
          ],
        ),
        SizedBox(height: spacing.xs),
        _MoneySplit(figures: figures),
        SizedBox(height: spacing.sm),
        _BucketPills(figures: figures),
        ..._notes(l10n, spacing),
        if (transactions.isNotEmpty)
          _TransactionList(
            transactions: transactions,
            onOpenOrder: onOpenOrder,
          ),
      ],
    );
  }

  /// One sentence per way the money went astray, most uncertain first.
  List<Widget> _notes(AppLocalizations l10n, AdaptiveSpacing spacing) {
    final notes = <Widget>[
      if (figures.unknown.count > 0)
        PointyInlineMessage.error(
          key: const ValueKey('session_integrations_unknown'),
          compact: true,
          icon: Icons.help_outline,
          message: l10n.sessionIntegrationsUnknownNote(figures.unknown.count),
        ),
      if (figures.refundedAfterDelivery.count > 0)
        PointyInlineMessage.error(
          key: const ValueKey('session_integrations_refunded_after_delivery'),
          compact: true,
          icon: Icons.money_off_outlined,
          message: l10n.sessionIntegrationsRefundedAfterDeliveryNote(
            figures.refundedAfterDelivery.count,
            formatMoney(figures.refundedAfterDelivery.cost),
          ),
        ),
      if (figures.awaiting.count > 0)
        PointyInlineMessage.warning(
          key: const ValueKey('session_integrations_awaiting'),
          compact: true,
          icon: Icons.schedule_outlined,
          message: l10n.sessionIntegrationsAwaitingNote(
            figures.awaiting.count,
            formatMoney(figures.awaiting.amount),
          ),
        ),
    ];
    return [
      for (final note in notes) ...[SizedBox(height: spacing.sm), note],
    ];
  }
}

/// What customers paid, the provider's share of it, and what the shop keeps.
class _MoneySplit extends StatelessWidget {
  const _MoneySplit({required this.figures});

  final SessionIntegrationFigures figures;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return PointySummaryList(
      rows: [
        PointySummaryRow(
          label: l10n.sessionIntegrationsSoldLabel,
          value: formatMoney(figures.sold),
        ),
        PointySummaryRow(
          label: l10n.sessionIntegrationsCostLabel,
          value: formatMoney(figures.cost),
        ),
        PointySummaryRow(
          label: l10n.sessionIntegrationsMarginLabel,
          value: formatMoney(figures.margin),
          emphasized: true,
          dividerAbove: true,
          valueColor: figures.margin < 0 ? colors.danger : colors.primaryStrong,
        ),
      ],
    );
  }
}

class _BucketPills extends StatelessWidget {
  const _BucketPills({required this.figures});

  final SessionIntegrationFigures figures;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final bucket in SessionIntegrationBucket.values)
          if (figures.bucket(bucket).count > 0)
            PointyStatusPill(
              key: ValueKey('session_integrations_pill_${bucket.name}'),
              icon: _bucketIcon(bucket),
              color: _bucketColor(bucket, colors),
              label: l10n.sessionIntegrationsBucketPill(
                _bucketLabel(bucket, l10n),
                figures.bucket(bucket).count,
                formatMoney(figures.bucket(bucket).amount),
              ),
            ),
      ],
    );
  }
}

/// Every transaction behind the figures, oldest first, one tap from its sale.
///
/// Collapsed by default: the notes above already say what went wrong and how
/// much of it; this is where somebody goes to find out which ones.
class _TransactionList extends StatelessWidget {
  const _TransactionList({required this.transactions, this.onOpenOrder});

  final List<SessionIntegrationTransaction> transactions;
  final ValueChanged<SessionIntegrationTransaction>? onOpenOrder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          l10n.sessionIntegrationsTransactionsToggle(transactions.length),
          style: theme.textTheme.titleSmall,
        ),
        children: [
          for (final transaction in transactions)
            _TransactionRow(
              key: ValueKey(
                'session_integration_transaction_${transaction.id}',
              ),
              transaction: transaction,
              onTap: onOpenOrder == null
                  ? null
                  : () => onOpenOrder!(transaction),
            ),
        ],
      ),
    );
  }
}

class _TransactionRow extends StatelessWidget {
  const _TransactionRow({super.key, required this.transaction, this.onTap});

  final SessionIntegrationTransaction transaction;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final bucket = transaction.bucket;
    final refundedAfterDelivery = transaction.isRefundedAfterDelivery;
    final tone = refundedAfterDelivery
        ? colors.danger
        : _bucketColor(bucket, colors);

    final title = [
      if (transaction.optionLabel.isNotEmpty)
        transaction.optionLabel
      else
        integrationProviderName(
          integrationProviderKeyFromJson(transaction.provider),
          l10n,
        ),
      // A card off the shelf has no number of its own until it is sold.
      if (transaction.subscriberRef.isNotEmpty)
        ltrIsolated(transaction.subscriberRef),
    ].join(' • ');
    final details = [
      if (transaction.soldAt != null) formatTime(transaction.soldAt!),
      if (transaction.receiptNumber.isNotEmpty)
        l10n.saleReceiptTitle(ltrIsolated(transaction.receiptNumber)),
      if (transaction.subscriberLabel.isNotEmpty)
        l10n.invoiceRechargeFor(transaction.subscriberLabel),
      if (bucket == SessionIntegrationBucket.delivered &&
          transaction.providerReference.isNotEmpty)
        l10n.invoiceRechargeReference(
          ltrIsolated(transaction.providerReference),
        ),
    ].join(' • ');
    final status = switch (bucket) {
      SessionIntegrationBucket.delivered => null,
      SessionIntegrationBucket.awaiting => [
        l10n.sessionIntegrationsBucketAwaiting,
        // Why it did not happen, when the provider said: an empty float is
        // the one a shop can fix itself.
        if (transaction.errorCode.isNotEmpty)
          integrationErrorText(transaction.errorCode, l10n),
      ].join(' — '),
      SessionIntegrationBucket.unknown => l10n.rechargeNeedsAttentionBadge,
      SessionIntegrationBucket.refunded => [
        refundedAfterDelivery
            ? l10n.sessionIntegrationsRefundedAfterDelivery
            : l10n.sessionIntegrationsBucketRefunded,
        l10n.sessionIntegrationsRefundedValue(
          formatMoney(transaction.refundedAmount),
        ),
      ].join(' • '),
    };

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(PointyRadii.card),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                refundedAfterDelivery
                    ? Icons.money_off_outlined
                    : _bucketIcon(bucket),
                size: 18,
                color: tone,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (details.isNotEmpty)
                    Text(
                      details,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                  if (status != null)
                    Text(
                      status,
                      style: theme.textTheme.bodySmall?.copyWith(color: tone),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatMoney(transaction.price),
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  l10n.sessionIntegrationsTransactionCost(
                    formatMoney(transaction.cost),
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _bucketLabel(SessionIntegrationBucket bucket, AppLocalizations l10n) {
  return switch (bucket) {
    SessionIntegrationBucket.delivered =>
      l10n.sessionIntegrationsBucketDelivered,
    SessionIntegrationBucket.awaiting => l10n.sessionIntegrationsBucketAwaiting,
    // Worded as the invoice words a sent-but-unanswered top-up, so the two
    // screens a manager moves between say the same thing about it.
    SessionIntegrationBucket.unknown => l10n.rechargeNeedsAttentionBadge,
    SessionIntegrationBucket.refunded => l10n.sessionIntegrationsBucketRefunded,
  };
}

IconData _bucketIcon(SessionIntegrationBucket bucket) {
  return switch (bucket) {
    SessionIntegrationBucket.delivered => Icons.check_circle_outline,
    SessionIntegrationBucket.awaiting => Icons.schedule_outlined,
    SessionIntegrationBucket.unknown => Icons.help_outline,
    SessionIntegrationBucket.refunded => Icons.undo_outlined,
  };
}

Color _bucketColor(
  SessionIntegrationBucket bucket,
  PointySemanticColors colors,
) {
  return switch (bucket) {
    SessionIntegrationBucket.delivered => colors.success,
    SessionIntegrationBucket.awaiting => colors.warning,
    SessionIntegrationBucket.unknown => colors.danger,
    SessionIntegrationBucket.refunded => colors.mutedInk,
  };
}
