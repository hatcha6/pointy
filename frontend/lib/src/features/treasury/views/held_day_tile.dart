import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/card_settlement.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import 'treasury_ui.dart';

/// One processor day of held card takings: its weekday, how many sales, when
/// its money should land, and what it should bring in.
///
/// Selectable on the settlement sheet (a checkbox, and a fold-out of the day's
/// sales so a sale the processor kept back can be left out); read-only in an
/// account's detail sheet, where [onToggle] is null.
class HeldDayTile extends StatelessWidget {
  const HeldDayTile({
    super.key,
    required this.day,
    this.selected = false,
    this.expanded = false,
    this.payments,
    this.isLoadingPayments = false,
    this.hasPaymentsError = false,
    this.isExcluded,
    this.onToggle,
    this.onToggleExpanded,
    this.onTogglePayment,
  });

  final HeldDay day;
  final bool selected;
  final bool expanded;
  final List<HeldPayment>? payments;
  final bool isLoadingPayments;
  final bool hasPaymentsError;
  final bool Function(HeldPayment payment)? isExcluded;
  final VoidCallback? onToggle;
  final VoidCallback? onToggleExpanded;
  final ValueChanged<HeldPayment>? onTogglePayment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    final header = Row(
      children: [
        if (onToggle != null)
          Checkbox(
            key: ValueKey('card_settlement_day_${day.key}'),
            value: selected,
            onChanged: (_) => onToggle!(),
          )
        else
          Padding(
            padding: EdgeInsetsDirectional.only(end: spacing.sm),
            child: Icon(
              Icons.event_note_outlined,
              size: 20,
              color: colors.mutedInk,
            ),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(treasuryDayLabel(l10n, day.day), style: textTheme.bodyLarge),
              Text(
                l10n.cardSettlementDaySubtitle(
                  day.count,
                  treasuryDayLabel(l10n, day.expectedOn),
                ),
                style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
            ],
          ),
        ),
        if (day.overdue) ...[
          PointyStatusPill(
            label: l10n.cardSettlementDayOverdue,
            icon: Icons.schedule,
            color: colors.danger,
          ),
          SizedBox(width: spacing.xs),
        ],
        Text(
          formatMoney(centsToDouble(day.netCents)),
          style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (onToggleExpanded != null)
          IconButton(
            key: ValueKey('card_settlement_expand_${day.key}'),
            tooltip: l10n.cardSettlementShowSales,
            onPressed: onToggleExpanded,
            icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
          ),
      ],
    );

    return Card(
      margin: EdgeInsets.only(bottom: spacing.sm),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: spacing.sm,
          vertical: spacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [header, if (expanded) ..._sales(context, l10n)],
        ),
      ),
    );
  }

  List<Widget> _sales(BuildContext context, AppLocalizations l10n) {
    final spacing = AdaptiveSpacing.of(context);
    if (isLoadingPayments) {
      return [
        Padding(
          padding: EdgeInsets.all(spacing.sm),
          child: const Center(child: PointySpinner(strokeWidth: 2)),
        ),
      ];
    }
    if (hasPaymentsError) {
      return [
        PointyInlineMessage.error(message: l10n.cardSettlementSalesFailed),
      ];
    }
    return [
      const Divider(height: 1),
      for (final payment in payments ?? const <HeldPayment>[])
        _SaleRow(
          payment: payment,
          // A sale can only be left out of a day that is being paid.
          enabled: selected && onTogglePayment != null,
          included: !(isExcluded?.call(payment) ?? false),
          onToggle: onTogglePayment == null
              ? null
              : () => onTogglePayment!(payment),
        ),
    ];
  }
}

class _SaleRow extends StatelessWidget {
  const _SaleRow({
    required this.payment,
    required this.enabled,
    required this.included,
    this.onToggle,
  });

  final HeldPayment payment;
  final bool enabled;
  final bool included;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final paidAt = payment.paidAt;
    final details = [
      if (paidAt != null) formatTime(paidAt),
      if (payment.isReversal) l10n.cardSettlementReversal,
      if (payment.maskedPan.isNotEmpty) payment.maskedPan,
      if (payment.terminalId.isNotEmpty) payment.terminalId,
    ].join(' · ');

    return Row(
      children: [
        Checkbox(
          key: ValueKey('card_settlement_payment_${payment.id}'),
          value: included,
          onChanged: enabled && onToggle != null ? (_) => onToggle!() : null,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                payment.invoiceNumber.isEmpty
                    ? '#${payment.id}'
                    : payment.invoiceNumber,
                style: textTheme.bodyMedium,
              ),
              if (details.isNotEmpty)
                Text(
                  details,
                  style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        Text(
          treasurySignedMoney(centsToDouble(payment.netCents)),
          style: textTheme.bodyMedium?.copyWith(
            color: included ? null : colors.mutedInk,
            decoration: included ? null : TextDecoration.lineThrough,
          ),
        ),
      ],
    );
  }
}
