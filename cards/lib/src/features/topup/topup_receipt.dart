import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/account_target.dart';
import '../../data/models/order.dart';
import '../../design/cards_tokens.dart';
import '../../shared/grouped.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';

/// The receipt: the account part by part under the game's own labels, the
/// player, what was paid, when, and the order's number to quote.
class TopUpReceipt extends StatelessWidget {
  const TopUpReceipt({
    super.key,
    required this.order,
    required this.target,
    required this.player,
  });

  final CardOrder order;
  final AccountTarget? target;
  final String player;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final local = MaterialLocalizations.of(context);
    final when = (order.completedAt ?? order.paidAt ?? order.createdAt)
        ?.toLocal();
    final values = order.accountValues;
    final fields = target?.fields
        .where((f) => (values[f.key] ?? '').isNotEmpty)
        .toList();
    return Grouped(
      children: [
        if (fields != null && fields.isNotEmpty)
          for (final field in fields)
            _ReceiptRow(
              label: field.label,
              value: _shown(field, values[field.key]!),
              ltr: !field.isSelect,
            )
        else if (order.account.isNotEmpty)
          _ReceiptRow(label: l10n.receiptTo, value: order.account, ltr: true),
        if (player.isNotEmpty)
          _ReceiptRow(label: l10n.receiptPlayer, value: player, ltr: true),
        _ReceiptRow(
          label: l10n.receiptPaid,
          value: formatMoney(l10n, order.total),
        ),
        if (when != null)
          _ReceiptRow(
            label: l10n.receiptWhen,
            // The app's digits are 0–9 throughout; the date names come in
            // the reader's language.
            value: asciiDigits(
              '${local.formatMediumDate(when)} · '
              '${local.formatTimeOfDay(TimeOfDay.fromDateTime(when))}',
            ),
          ),
        _ReceiptRow(
          label: l10n.receiptOrder,
          value: order.id,
          ltr: true,
          small: true,
          onTap: () {
            Clipboard.setData(ClipboardData(text: order.id));
            Haptics.select();
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(l10n.orderIdCopied)));
          },
        ),
      ],
    );
  }

  /// A value as the receipt shows it: a choice by its label, and an invite
  /// link by its friend code alone (its token is what lets anyone in).
  String _shown(TargetField field, String value) {
    if (field.isSelect) {
      return field.optionLabel(value);
    }
    if (target?.kind == TargetKind.steamInvite) {
      final match = RegExp(r's\.team/p/[^/\s]+').firstMatch(value);
      return match?.group(0) ?? value;
    }
    if (target?.kind == TargetKind.telegram) {
      return '@$value';
    }
    return value;
  }
}

class _ReceiptRow extends StatelessWidget {
  const _ReceiptRow({
    required this.label,
    required this.value,
    this.ltr = false,
    this.small = false,
    this.onTap,
  });

  final String label;
  final String value;
  final bool ltr;
  final bool small;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = small
        ? theme.textTheme.bodySmall
        : theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CardsSpace.lg,
          vertical: CardsSpace.md,
        ),
        child: Row(
          children: [
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: CardsSpace.lg),
            Expanded(
              child: Text(
                value,
                // Every value against the row's far edge, an ID's too.
                textAlign: Directionality.of(context) == TextDirection.rtl
                    ? TextAlign.left
                    : TextAlign.right,
                textDirection: ltr ? TextDirection.ltr : null,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: style == null ? null : PointyTypography.numeric(style),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: CardsSpace.sm),
              Icon(
                Icons.copy_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
