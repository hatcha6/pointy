import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/order.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/cards_scope.dart';
import '../../shared/money_text.dart';

/// On a bundle delivered without one of its cards: the card that could not
/// be bought, greyed, and the money for it back in the customer's credit.
/// Calm, never red, as every refund in the app: the money is safe.
class BundleRefundNote extends StatelessWidget {
  const BundleRefundNote({super.key, required this.order});

  final CardOrder order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final catalog = CardsScope.of(context).catalog;
    final accent = theme.colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.all(CardsSpace.md),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(CardsRadii.tile),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final itemKey in order.bundleRefunded)
            if (catalog.cardOfItem(itemKey) case final card)
              Padding(
                padding: const EdgeInsets.only(bottom: CardsSpace.sm),
                child: Row(
                  children: [
                    if (card != null) ...[
                      SizedBox(
                        width: 56,
                        child: CardArt(
                          brand: card.brand,
                          radius: 6,
                          muted: true,
                          shadow: false,
                        ),
                      ),
                      const SizedBox(width: CardsSpace.md),
                    ],
                    Expanded(
                      child: Text(
                        l10n.bundleCardRefundedTitle(
                          card == null
                              ? itemKey
                              : '${card.brand.name} · ${card.item.label}',
                        ),
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
              ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.account_balance_wallet_rounded,
                size: 18,
                color: accent,
              ),
              const SizedBox(width: CardsSpace.sm),
              Expanded(
                child: Text(
                  l10n.refundedBody(formatMoney(l10n, order.refunded)),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
