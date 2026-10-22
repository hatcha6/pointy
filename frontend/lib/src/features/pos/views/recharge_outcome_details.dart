import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/integration_card.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../settings/views/integration_presentation.dart';

/// What the provider did about each card or top-up a sale sold, when it was
/// not simply "done".
///
/// The outcomes need different reactions and the dialog says so outright,
/// because the wrong reaction to the last one spends the shop's money twice:
///
/// * **refused** — nothing was delivered. The server has already returned the
///   line in this drawer, so the dialog names the amount to hand back. (A
///   server from before that leaves the sale paid; then only the reason shows.)
/// * **unknown** — the request left and never answered. Do not retry, do not
///   refund. Check the card with the provider; reconciliation will settle it
///   against their own purchase log.
///
/// Shown inside the sale's result (see `PosCheckoutDialog`), which keeps it
/// on screen until the cashier closes it when any row is unknown.
class RechargeOutcomeDetails extends StatelessWidget {
  const RechargeOutcomeDetails({super.key, required this.rows});

  final List<IntegrationChargeResult> rows;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final unresolved = rows.where((row) => row.needsAttention).toList();
    final failed = rows.where((row) => row.isRefused).toList();
    final refundTotal = failed.fold<double>(
      0,
      (sum, row) => sum + (row.refundAmount ?? 0),
    );

    return Column(
      key: const ValueKey('recharge_outcome_details'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              unresolved.isEmpty ? Icons.error_outline : Icons.help_outline,
              size: 20,
              color: unresolved.isEmpty ? colors.danger : colors.warning,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                unresolved.isEmpty
                    ? l10n.rechargeRefusedTitle
                    : l10n.rechargeUnknownTitle,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (unresolved.isNotEmpty) ...[
              Text(l10n.rechargeUnknownBody),
              const SizedBox(height: 12),
            ],
            for (final row in [...unresolved, ...failed])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        row.subscriberRef,
                        row.optionLabel,
                      ].where((part) => part.trim().isNotEmpty).join(' · '),
                      style: textTheme.titleSmall,
                    ),
                    Text(
                      integrationErrorText(
                        row.errorCode,
                        l10n,
                        provider: row.provider,
                      ),
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                    if (row.refundAmount case final amount?)
                      Text(
                        l10n.rechargeRefundedLine(formatMoney(amount)),
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.danger,
                        ),
                      ),
                  ],
                ),
              ),
            if (refundTotal > 0) ...[
              const SizedBox(height: 4),
              Text(
                l10n.rechargeRefundedTotal(formatMoney(refundTotal)),
                key: const ValueKey('recharge_outcome_refund_total'),
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
