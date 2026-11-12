import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/order/order.dart';
import '../../../shared/unit_options.dart';
import '../view_models/purchase_view_model.dart';
import 'purchase_line_capture_row.dart';

/// The stops Enter makes on a purchase line, in the order an invoice row is
/// read. The unit comes before the cost because the cost is per that unit —
/// switching unit rescales it, so a cost typed first would be rewritten.
enum PurchaseLineEntryStep { quantity, unit, cost, expiry }

/// The units [line] can be bought in.
List<UnitOption> purchaseLineUnitOptions(
  AppLocalizations l10n,
  PurchaseDraftLine line,
) => purchasableUnitOptions(l10n, Product.fromVariant(line.variant));

/// The stops [line] actually has: a product bought in one unit has no unit to
/// choose, and only a dated single-lot line shows its expiry inline.
List<PurchaseLineEntryStep> purchaseLineEntrySteps(
  AppLocalizations l10n,
  PurchaseDraftLine line,
) => [
  PurchaseLineEntryStep.quantity,
  if (purchaseLineUnitOptions(l10n, line).length > 1)
    PurchaseLineEntryStep.unit,
  PurchaseLineEntryStep.cost,
  if (PurchaseLineCaptureRow.hasInlineExpiry(line))
    PurchaseLineEntryStep.expiry,
];

/// Moves [line] to its next purchasable unit ([key] null, or an arrow Up/Right)
/// or its previous one (arrow Down/Left). The one unit cycle behind F2, the
/// arrows and the walk's unit stop. False when the product has one unit.
bool cyclePurchaseLineUnit(
  AppLocalizations l10n,
  PurchaseViewModel viewModel,
  PurchaseDraftLine line, [
  LogicalKeyboardKey? key,
]) {
  final next = cycledUnitOption(
    purchaseLineUnitOptions(l10n, line),
    line.unitCode,
    key,
  );
  if (next == null) {
    return false;
  }
  viewModel.updateLineUnit(
    line.variant,
    unitCode: next.isBase ? '' : next.code,
    unitLabel: next.label,
    unitFactor: next.factorToBase,
    allowsFractional: next.allowsFractional,
  );
  return true;
}

/// Where the keyboard is on the line being entered, and what the keys do
/// there. Shown under the draft's lines for as long as a line is being
/// walked, so the walk never has to be memorised from the shortcuts sheet.
class PurchaseLineEntryGuide extends StatelessWidget {
  const PurchaseLineEntryGuide({
    super.key,
    required this.steps,
    required this.current,
  });

  final List<PurchaseLineEntryStep> steps;
  final PurchaseLineEntryStep current;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final isLast = steps.isNotEmpty && steps.last == current;
    final onField =
        current == PurchaseLineEntryStep.cost ||
        current == PurchaseLineEntryStep.expiry;

    String stepLabel(PurchaseLineEntryStep step) => switch (step) {
      PurchaseLineEntryStep.quantity => l10n.purchaseLineQuantityLabel,
      PurchaseLineEntryStep.unit => l10n.purchaseEntryStepUnit,
      PurchaseLineEntryStep.cost => l10n.purchaseLineCostLabel,
      PurchaseLineEntryStep.expiry => l10n.purchaseEntryStepExpiry,
    };

    Widget hint(List<String> keys, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final key in keys) ...[
          PointyKeycap(label: key, dense: true),
          const SizedBox(width: 3),
        ],
        const SizedBox(width: 2),
        // Flexible: in the narrowest draft pane a hint is cut short rather
        // than pushed past the edge.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: colors.mutedInk),
          ),
        ),
      ],
    );

    return Container(
      key: const ValueKey('purchase_line_entry_guide'),
      width: double.infinity,
      padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final (index, step) in steps.indexed) ...[
                if (index > 0)
                  Icon(
                    // Points the way the steps are read.
                    Directionality.of(context) == TextDirection.rtl
                        ? Icons.chevron_left
                        : Icons.chevron_right,
                    size: 14,
                    color: colors.mutedInk,
                  ),
                _StepChip(
                  key: ValueKey('purchase_entry_step_${step.name}'),
                  label: stepLabel(step),
                  active: step == current,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              hint(
                const ['Enter'],
                isLast
                    ? l10n.purchaseEntryGuideDone
                    : l10n.purchaseEntryGuideNext,
              ),
              if (current == PurchaseLineEntryStep.unit)
                hint(const ['↑', '↓'], l10n.purchaseEntryGuideChangeUnit)
              else
                hint(
                  const ['↑', '↓'],
                  onField
                      ? l10n.purchaseEntryGuideSameField
                      : l10n.purchaseEntryGuideLines,
                ),
              if (current == PurchaseLineEntryStep.quantity &&
                  steps.contains(PurchaseLineEntryStep.unit))
                hint(const ['←', '→'], l10n.purchaseEntryGuideChangeUnit),
              hint(const ['Esc'], l10n.purchaseEntryGuideSearch),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepChip extends StatelessWidget {
  const _StepChip({super.key, required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: active ? colors.primaryStrong : Colors.transparent,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: active ? theme.colorScheme.onPrimary : colors.mutedInk,
          fontWeight: active ? FontWeight.w800 : FontWeight.w500,
        ),
      ),
    );
  }
}
