import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/esim.dart';
import '../../design/cards_tokens.dart';
import '../../shared/esim_card_art.dart';
import 'esim_format.dart';

/// What the customer most wants to know: how much is left, until when.
class EsimUsageCard extends StatelessWidget {
  const EsimUsageCard({super.key, required this.esim});

  final CustomerEsim esim;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final usage = esim.usage;
    final now = DateTime.now();
    final left = usage.left;
    final days = usage.daysLeft(now);
    return Container(
      padding: const EdgeInsets.all(CardsSpace.lg),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(CardsRadii.card),
        boxShadow: CardsShadows.raised,
        border: Border.all(
          color: scheme.outline.withValues(alpha: 0.6),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              EsimFlag(country: esim.country, width: 48),
              const SizedBox(width: CardsSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    EsimPlanLine(
                      data: esim.data,
                      days: esim.days,
                      unlimited: esim.unlimited,
                      style: theme.textTheme.titleMedium,
                    ),
                    if (esim.label.isNotEmpty)
                      Text(
                        l10n.esimForName(esim.label),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              Text(
                esimStatusText(l10n, usage.status),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: usage.over
                      ? scheme.error
                      : usage.status == EsimStatus.active
                      ? scheme.tertiary
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (esim.unlimited && usage.status == EsimStatus.active) ...[
            const SizedBox(height: CardsSpace.lg),
            Text(l10n.esimUnlimited, style: theme.textTheme.titleLarge),
          ] else if (left != null) ...[
            const SizedBox(height: CardsSpace.lg),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: CardsSpace.xs,
              children: [
                EsimLtr(
                  formatEsimData(usage.remainingMb),
                  style: theme.textTheme.headlineSmall,
                ),
                Text(
                  l10n.esimLeftOf,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                EsimLtr(
                  formatEsimData(usage.totalMb),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: CardsSpace.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(CardsRadii.pill),
              child: LinearProgressIndicator(
                value: left,
                minHeight: 8,
                color: usage.dataLow ? scheme.error : scheme.primary,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ],
          if (days != null && usage.status == EsimStatus.active) ...[
            const SizedBox(height: CardsSpace.sm),
            Text(
              days == 0 ? l10n.esimEndsToday : l10n.esimEndsInDays(days),
              style: theme.textTheme.bodySmall?.copyWith(
                color: days <= 3 ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
