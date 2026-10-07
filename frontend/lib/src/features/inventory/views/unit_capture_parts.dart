import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/receipt_capture.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';

/// The lot every article in the scan loop is born into (`serial_batch`).
///
/// Shown above the scan field because a receiver with three cartons open has
/// to know which one they are scanning — the lot was typed on the sheet
/// before, and the loop used to give no sign of it.
class UnitCaptureLotBanner extends StatelessWidget {
  const UnitCaptureLotBanner({super.key, required this.lot});

  final ReceiptBatchCapture lot;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final expiry = lot.expiryDate;
    return Container(
      key: const ValueKey('unit-capture-lot-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.inventory_2_outlined, size: 18, color: colors.primaryDark),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              expiry == null
                  ? l10n.unitCaptureLotBanner(lot.code)
                  : l10n.unitCaptureLotBannerExpiry(
                      lot.code,
                      formatDate(expiry),
                    ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.primaryDark,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether a scanned article's condition is on record yet.
enum UnitDetailsState { notOffered, missing, described, missingRequired }

/// One scanned article: its number, what is known about it, and the controls
/// for its cost and its details.
///
/// Two layouts, because the controls do not fit beside a 15-digit IMEI on a
/// phone: on a wide sheet everything sits on one line; on a narrow one the
/// cost and the details button drop to a second line under the number.
class CapturedUnitRow extends StatelessWidget {
  const CapturedUnitRow({
    super.key,
    required this.index,
    required this.unit,
    required this.summary,
    required this.detailsState,
    required this.showsCost,
    required this.onRemove,
    required this.onCostChanged,
    this.detailsLabel = '',
    this.detailsIsPriceOnly = false,
    this.onEditDetails,
  });

  final int index;
  final ReceiptUnitCapture unit;

  /// What was recorded about it, already formatted for one line.
  final String summary;
  final UnitDetailsState detailsState;
  final bool showsCost;
  final VoidCallback onRemove;
  final ValueChanged<double?> onCostChanged;
  final String detailsLabel;

  /// Nothing to record but a price: the button shows a price tag, not a
  /// checklist.
  final bool detailsIsPriceOnly;

  /// Null when there is nothing to record about this kind of article.
  final VoidCallback? onEditDetails;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    final status = switch (detailsState) {
      UnitDetailsState.missingRequired => (
        l10n.unitCaptureMissingRequired,
        colors.warning,
      ),
      UnitDetailsState.missing when summary.isEmpty => (
        l10n.unitCaptureNotDescribed,
        colors.mutedInk,
      ),
      _ => ('', colors.mutedInk),
    };
    final hasSubtitle = summary.isNotEmpty || status.$1.isNotEmpty;

    final identity = Row(
      children: [
        _RowNumber(
          number: index + 1,
          done: detailsState != UnitDetailsState.missingRequired,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                unit.code,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.ltr,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (hasSubtitle)
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: summary),
                      if (summary.isNotEmpty && status.$1.isNotEmpty)
                        const TextSpan(text: ' · '),
                      if (status.$1.isNotEmpty)
                        TextSpan(
                          text: status.$1,
                          style: TextStyle(color: status.$2),
                        ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    final cost = showsCost
        ? _CostField(
            key: ValueKey('unit-capture-cost-${unit.code}'),
            unit: unit,
            onChanged: onCostChanged,
          )
        : null;
    final details = onEditDetails == null
        ? null
        : _DetailsButton(
            key: ValueKey('unit-capture-details-${unit.code}'),
            label: detailsLabel,
            state: detailsState,
            priceOnly: detailsIsPriceOnly,
            onPressed: onEditDetails!,
          );
    final remove = IconButton(
      tooltip: l10n.unitCaptureRemoveTooltip,
      icon: const Icon(Icons.close, size: 18),
      onPressed: onRemove,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 560;
          if (wide || (cost == null && details == null)) {
            return Row(
              children: [
                Expanded(child: identity),
                if (cost != null) ...[
                  const SizedBox(width: 8),
                  SizedBox(width: 132, child: cost),
                ],
                if (details != null) ...[const SizedBox(width: 4), details],
                remove,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: identity),
                  remove,
                ],
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 36, top: 4),
                child: Row(
                  children: [
                    if (cost != null) Expanded(child: cost),
                    if (cost != null && details != null)
                      const SizedBox(width: 8),
                    if (details != null)
                      cost == null ? Expanded(child: details) : details,
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RowNumber extends StatelessWidget {
  const _RowNumber({required this.number, required this.done});

  final int number;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final color = done ? colors.primaryStrong : colors.warning;
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1.5),
      ),
      child: Text(
        '$number',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DetailsButton extends StatelessWidget {
  const _DetailsButton({
    super.key,
    required this.label,
    required this.state,
    required this.onPressed,
    this.priceOnly = false,
  });

  final String label;
  final UnitDetailsState state;
  final bool priceOnly;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final described = state == UnitDetailsState.described;
    final color = state == UnitDetailsState.missingRequired
        ? colors.warning
        : colors.primaryStrong;
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 40),
      ),
      icon: Icon(
        priceOnly
            ? Icons.sell_outlined
            : described
            ? Icons.fact_check
            : Icons.fact_check_outlined,
        size: 18,
      ),
      label: Text(label, maxLines: 1),
    );
  }
}

/// One article's share of the line cost. Wide enough for 99999.99 — a used
/// handset's cost is four digits, and the old 96-pixel box cut «4100.00» to
/// «4100.0».
class _CostField extends StatelessWidget {
  const _CostField({super.key, required this.unit, required this.onChanged});

  final ReceiptUnitCapture unit;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return TextFormField(
      initialValue: unit.unitCost?.toStringAsFixed(2) ?? '',
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        isDense: true,
        labelText: l10n.unitCaptureCostFieldLabel,
      ),
      onChanged: (value) => onChanged(double.tryParse(value.trim())),
    );
  }
}
