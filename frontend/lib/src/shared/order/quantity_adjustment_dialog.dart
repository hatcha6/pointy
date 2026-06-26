import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'pointy_quantity_stepper.dart';

/// View-data for a single line a user can pick a quantity from, in a
/// [QuantityAdjustmentDialog] or a standalone [AdjustmentLineStepper].
///
/// Each owning feature maps its own domain line (a sale order line, a purchase
/// order line, …) onto this shape, which keeps the shared widgets free of any
/// document-specific knowledge.
class AdjustmentLineOption {
  const AdjustmentLineOption({
    required this.lineId,
    required this.title,
    required this.subtitle,
    required this.maxQuantity,
    this.allowDecimal = false,
    this.decimalEntryTitle,
    this.decimalEntryHint,
  });

  /// Identifier echoed back in the matching [AdjustmentLineSelection.lineId].
  final int lineId;
  final String title;
  final String subtitle;

  /// Upper bound for the selectable quantity (the returnable / adjustable
  /// amount remaining on the line).
  final double maxQuantity;

  /// When true the stepper offers tap-to-type fractional entry (weighed
  /// goods). Whole-unit flows such as purchasing leave this false so the
  /// quantity can only move in steps of one.
  final bool allowDecimal;

  /// Title and helper text for the tap-to-type entry dialog. Only consulted
  /// when [allowDecimal] is true; supplied by the caller so the shared widget
  /// stays localization-agnostic.
  final String? decimalEntryTitle;
  final String? decimalEntryHint;
}

/// A single non-zero line chosen in a [QuantityAdjustmentDialog].
class AdjustmentLineSelection {
  const AdjustmentLineSelection({required this.lineId, required this.quantity});

  final int lineId;
  final double quantity;
}

/// Outcome of a [QuantityAdjustmentDialog]: the chosen line quantities plus the
/// free-text reason.
class QuantityAdjustmentResult {
  const QuantityAdjustmentResult({required this.lines, required this.reason});

  final List<AdjustmentLineSelection> lines;
  final String reason;
}

/// Shows the shared "pick a quantity per line, then give a reason" dialog used
/// by both sales returns and purchase returns/refunds. Returns null when the
/// dialog is dismissed.
///
/// Callers pass [options] already filtered to the lines that can be adjusted;
/// an empty list renders [emptyMessage].
Future<QuantityAdjustmentResult?> showQuantityAdjustmentDialog(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String emptyMessage,
  required String reasonLabel,
  required String reasonHint,
  required List<AdjustmentLineOption> options,
}) {
  return showDialog<QuantityAdjustmentResult>(
    context: context,
    builder: (context) => QuantityAdjustmentDialog(
      icon: icon,
      title: title,
      emptyMessage: emptyMessage,
      reasonLabel: reasonLabel,
      reasonHint: reasonHint,
      options: options,
    ),
  );
}

/// A reason-carrying, per-line quantity picker shared by every order
/// adjustment flow (sales returns, purchase returns, purchase refunds).
class QuantityAdjustmentDialog extends StatefulWidget {
  const QuantityAdjustmentDialog({
    super.key,
    required this.icon,
    required this.title,
    required this.emptyMessage,
    required this.reasonLabel,
    required this.reasonHint,
    required this.options,
  });

  final IconData icon;
  final String title;
  final String emptyMessage;
  final String reasonLabel;
  final String reasonHint;
  final List<AdjustmentLineOption> options;

  @override
  State<QuantityAdjustmentDialog> createState() =>
      _QuantityAdjustmentDialogState();
}

class _QuantityAdjustmentDialogState extends State<QuantityAdjustmentDialog> {
  late final Map<int, double> _quantities = {
    for (final option in widget.options) option.lineId: 0,
  };
  final TextEditingController _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      icon: Icon(widget.icon),
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.options.isEmpty)
                Text(widget.emptyMessage)
              else
                for (final option in widget.options)
                  AdjustmentLineStepper(
                    option: option,
                    value: _quantities[option.lineId] ?? 0,
                    onChanged: (value) {
                      setState(() => _quantities[option.lineId] = value);
                    },
                  ),
              const SizedBox(height: 12),
              AdjustmentReasonField(
                controller: _reasonController,
                label: widget.reasonLabel,
                hint: widget.reasonHint,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              QuantityAdjustmentResult(
                lines: [
                  for (final option in widget.options)
                    if ((_quantities[option.lineId] ?? 0) > 0)
                      AdjustmentLineSelection(
                        lineId: option.lineId,
                        quantity: _quantities[option.lineId]!,
                      ),
                ],
                reason: _reasonController.text.trim(),
              ),
            );
          },
          child: Text(l10n.confirmButton),
        ),
      ],
    );
  }
}

/// One line row in an adjustment dialog: a title/subtitle paired with a
/// [PointyQuantityStepper] bounded by [AdjustmentLineOption.maxQuantity].
///
/// For decimal lines (e.g. weighed goods) tapping the quantity opens a
/// tap-to-type entry dialog.
class AdjustmentLineStepper extends StatelessWidget {
  const AdjustmentLineStepper({
    super.key,
    required this.option,
    required this.value,
    required this.onChanged,
  });

  final AdjustmentLineOption option;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final canTypeDecimal =
        option.allowDecimal && option.decimalEntryTitle != null;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(option.title),
      subtitle: Text(option.subtitle),
      trailing: PointyQuantityStepper(
        quantity: value,
        incrementTooltip: l10n.addOneTooltip,
        decrementTooltip: l10n.removeOneTooltip,
        onDecrement: value <= 0 ? null : () => onChanged(value - 1),
        onIncrement: value >= option.maxQuantity
            ? null
            : () => onChanged(
                (value + 1).clamp(0, option.maxQuantity).toDouble(),
              ),
        onQuantityTap: canTypeDecimal ? () => _editDecimal(context) : null,
      ),
    );
  }

  Future<void> _editDecimal(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(
      text: value > 0 ? formatSaleQuantity(value) : '',
    );
    final entered = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(option.decimalEntryTitle!),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: option.decimalEntryTitle!,
            helperText: option.decimalEntryHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(double.tryParse(controller.text.trim())),
            child: Text(l10n.confirmButton),
          ),
        ],
      ),
    );
    controller.dispose();
    if (entered == null || entered < 0) {
      return;
    }
    onChanged(entered.clamp(0, option.maxQuantity).toDouble());
  }
}

/// The two-line free-text "reason" field shared by every adjustment dialog.
class AdjustmentReasonField extends StatelessWidget {
  const AdjustmentReasonField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
  });

  final TextEditingController controller;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(labelText: label, hintText: hint),
      maxLines: 2,
    );
  }
}
