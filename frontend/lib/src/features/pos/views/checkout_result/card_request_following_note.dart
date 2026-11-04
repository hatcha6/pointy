import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/integration_card.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';

/// The sale is done and the supplier is still working: the cashier is told so,
/// and that there is nothing to wait for and nothing to do again.
class CardRequestFollowingNote extends StatelessWidget {
  const CardRequestFollowingNote({
    super.key,
    required this.rows,
    this.receiptFollows = false,
  });

  final List<IntegrationChargeResult> rows;
  final bool receiptFollows;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      key: const ValueKey('checkout_card_request_following'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(PointyRadii.input),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.hourglass_top_rounded,
            size: 20,
            color: colors.primaryDark,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.cardRequestFollowingTitle,
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colors.ink,
                  ),
                ),
                const SizedBox(height: 2),
                for (final row in rows)
                  Text(
                    row.subscriberRef.isEmpty
                        ? row.optionLabel
                        : '${row.optionLabel} ${ltrIsolated(row.subscriberRef)}',
                    style: textTheme.bodyMedium?.copyWith(color: colors.ink),
                  ),
                const SizedBox(height: 2),
                Text(
                  receiptFollows
                      ? l10n.cardRequestFollowingHintPrint
                      : l10n.cardRequestFollowingHint,
                  style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Credit that reached an account while the customer waited: no code to hand
/// over, so the cashier reads out whose account it reached.
class AccountDeliveredNote extends StatelessWidget {
  const AccountDeliveredNote({super.key, required this.rows});

  final List<IntegrationChargeResult> rows;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      key: const ValueKey('checkout_account_delivered'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.success.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(PointyRadii.input),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle_rounded, size: 20, color: colors.success),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.cardRequestDelivered,
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colors.ink,
                  ),
                ),
                for (final row in rows)
                  Text(
                    '${row.optionLabel} ${ltrIsolated(row.receipt['account'] ?? row.subscriberRef)}',
                    style: textTheme.bodyMedium?.copyWith(color: colors.ink),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
