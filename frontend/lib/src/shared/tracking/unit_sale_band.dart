import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/stock_unit.dart';
import '../components/components.dart';
import '../date_formatters.dart';
import '../design/design.dart';

/// «بيع إلى أحمد علي» — the answer somebody typing an IMEI usually came for,
/// on the catalog's identifier match and on the article's own page.
///
/// Who bought the article, when, on which invoice, and whether it is still
/// covered. The buyer and the invoice are links when the reader may open
/// them; when the reader may not see them at all the payload never carried
/// them, and the band says only when it was sold.
class UnitSaleBand extends StatelessWidget {
  const UnitSaleBand({
    super.key,
    required this.unit,
    this.warranty,
    this.onOpenInvoice,
    this.onOpenCustomer,
  });

  final StockUnit unit;

  /// The server's warranty answer for this article, when it is the one the
  /// lookup answered about; the unit's own stamped date is used otherwise.
  final StockUnitWarranty? warranty;
  final ValueChanged<int>? onOpenInvoice;
  final ValueChanged<int>? onOpenCustomer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final name = unit.customerName;
    final soldAt = unit.soldAt;
    final title = switch (name) {
      final String known when known.isNotEmpty => l10n.unitSearchSoldTo(known),
      // Sent, and empty: a sale nobody named a customer on.
      '' => l10n.unitSearchSoldWalkIn,
      // Not sent: the reader may not know who bought it — only when.
      _ =>
        soldAt != null
            ? l10n.unitSearchSoldOn(formatDate(soldAt))
            : l10n.stockUnitStatusSold,
    };
    final showsDate = name != null && soldAt != null;
    final customerId = unit.customerId;
    final orderId = unit.soldOrderId;
    final receipt = unit.soldReceiptNumber ?? '';
    final openCustomer = onOpenCustomer;
    final openInvoice = onOpenInvoice;

    return Container(
      key: const ValueKey('unit_sale_band'),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          colors.primaryStrong.withValues(alpha: 0.07),
          colors.surface,
        ),
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        border: Border.all(color: colors.primaryStrong.withValues(alpha: 0.18)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.receipt_long_outlined,
                size: 20,
                color: colors.primaryStrong,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(
                    color: colors.primaryDark,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (showsDate) ...[
                const SizedBox(width: 8),
                Text(
                  formatDate(soldAt),
                  style: PointyTypography.numeric(
                    textTheme.bodySmall!.copyWith(color: colors.mutedInk),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (customerId != null && (name ?? '').isNotEmpty)
                _LinkChip(
                  key: const ValueKey('unit_search_customer_link'),
                  icon: Icons.person_outline_rounded,
                  label: name!,
                  tooltip: l10n.unitSearchOpenCustomerTooltip,
                  onTap: openCustomer == null
                      ? null
                      : () => openCustomer(customerId),
                ),
              if (orderId != null && receipt.isNotEmpty)
                _LinkChip(
                  key: const ValueKey('unit_search_invoice_link'),
                  icon: Icons.request_quote_outlined,
                  label: l10n.unitSearchInvoice('\u2066$receipt\u2069'),
                  tooltip: l10n.unitSearchOpenInvoiceTooltip,
                  onTap: openInvoice == null
                      ? null
                      : () => openInvoice(orderId),
                ),
              ..._warrantyPills(context),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _warrantyPills(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final expires = warranty?.expiresOn ?? unit.warrantyExpiresOn;
    final covered = warranty?.isCovered ?? unit.isUnderWarranty;
    final repairs = warranty?.repairCount ?? 0;
    return [
      if (expires == null)
        PointyStatusPill(
          label: l10n.unitWarrantyNone,
          icon: Icons.shield_outlined,
          color: colors.mutedInk,
        )
      else if (covered)
        PointyStatusPill(
          label: l10n.stockUnitWarrantyUntil(formatDate(expires)),
          icon: Icons.verified_user_outlined,
          color: colors.success,
        )
      else
        PointyStatusPill(
          label:
              '${l10n.unitWarrantyRowLabel} · '
              '${l10n.unitWarrantyExpiredOn(formatDate(expires))}',
          icon: Icons.gpp_maybe_outlined,
          color: colors.warning,
        ),
      if (repairs > 0)
        PointyStatusPill(
          label: l10n.unitSearchRepairs(repairs),
          icon: Icons.build_outlined,
          color: colors.mutedInk,
        ),
    ];
  }
}

/// A buyer or an invoice, as a small pill that opens it when it can.
class _LinkChip extends StatelessWidget {
  const _LinkChip({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final active = onTap != null;
    final accent = active ? colors.primaryStrong : colors.ink;
    final chip = Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(PointyRadii.chip),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        child: Container(
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 10, 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(PointyRadii.chip),
            border: Border.all(
              color: active
                  ? colors.primaryStrong.withValues(alpha: 0.35)
                  : colors.line,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelMedium?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return active ? Tooltip(message: tooltip, child: chip) : chip;
  }
}
