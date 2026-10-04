import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/money_position.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import 'treasury_ui.dart';

/// Card takings the processor is holding: how much, which bank it goes to,
/// how many days are waiting, and whether any of them is late.
///
/// Like every account card it carries no controls — recording a deposit lives
/// in the quick actions and in the sheet this card opens — but unlike a bank
/// its question is not "does it match a count" but "has it arrived yet".
class ClearingAccountCard extends StatelessWidget {
  const ClearingAccountCard({
    super.key,
    required this.entry,
    required this.onTap,
  });

  final MoneyAccountPosition entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final account = entry.account;
    final held = entry.held;

    final status = <Widget>[
      if (!account.isActive)
        PointyStatusPill(
          label: l10n.treasuryClearingClosed,
          icon: Icons.pause_circle_outline,
          color: colors.mutedInk,
        ),
      if (held == null || held.isEmpty)
        PointyStatusPill(
          label: l10n.treasuryClearingNothingHeld,
          icon: Icons.check_circle_outline,
          color: colors.success,
        )
      else ...[
        PointyStatusPill(
          label: l10n.treasuryClearingHeldDays(held.days),
          icon: Icons.hourglass_bottom_outlined,
          color: colors.mutedInk,
        ),
        if (held.hasOverdue)
          PointyStatusPill(
            key: ValueKey('treasury_clearing_overdue_${account.id}'),
            label: l10n.treasuryClearingOverdue(
              formatMoney(held.overdueAmount),
            ),
            icon: Icons.schedule,
            color: colors.danger,
          )
        else if (held.nextExpectedOn != null)
          Text(
            l10n.treasuryClearingExpectedOn(
              treasuryDayLabel(l10n, held.nextExpectedOn!),
            ),
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
      ],
    ];

    return Card(
      key: ValueKey('treasury_clearing_card_${account.id}'),
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: Padding(
          padding: EdgeInsets.all(spacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.primaryStrong,
                child: Icon(treasuryAccountIcon(account)),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.name,
                      style: textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (account.settlesIntoName.isNotEmpty)
                      Text(
                        l10n.treasuryClearingSettlesInto(
                          account.settlesIntoName,
                        ),
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    SizedBox(height: spacing.xs),
                    Text(
                      formatMoney(entry.expectedBalance),
                      style: textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: spacing.xs),
                    Wrap(
                      spacing: spacing.xs,
                      runSpacing: spacing.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: status,
                    ),
                  ],
                ),
              ),
              const PointyDisclosureChevron(),
            ],
          ),
        ),
      ),
    );
  }
}
