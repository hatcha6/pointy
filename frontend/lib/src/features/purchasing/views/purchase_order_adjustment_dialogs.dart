part of 'purchase_order_details_screen.dart';

/// Maps a purchase order's adjustable lines onto the shared
/// [AdjustmentLineOption] shape used by [showQuantityAdjustmentDialog] and the
/// exchange dialog's outbound section. Purchasing deals in whole units, so the
/// options never allow decimal entry.
List<AdjustmentLineOption> _purchaseAdjustmentOptions(
  AppLocalizations l10n,
  PurchaseOrder order,
) {
  return [
    for (final line in order.lines)
      if (line.adjustableQuantity > 0)
        AdjustmentLineOption(
          lineId: line.id,
          title: line.displayName.isEmpty
              ? l10n.purchaseOrderUnknownProduct
              : line.displayName,
          subtitle: [
            l10n.purchaseOrderLineQuantity(line.quantity),
            l10n.unitPriceEach(formatMoney(line.unitCost)),
            l10n.purchaseAdjustmentLineRemaining(
              line.adjustableQuantity,
              line.quantity,
            ),
          ].join(' • '),
          maxQuantity: line.adjustableQuantity.toDouble(),
        ),
  ];
}

/// Converts the shared dialog's selections back into purchasing's whole-unit
/// draft model.
List<PurchaseAdjustmentLineDraft> _purchaseAdjustmentDrafts(
  List<AdjustmentLineSelection> selections,
) {
  return [
    for (final selection in selections)
      PurchaseAdjustmentLineDraft(
        lineId: selection.lineId,
        quantity: selection.quantity.round(),
      ),
  ];
}

class _PurchaseExchangeDialog extends StatefulWidget {
  const _PurchaseExchangeDialog({required this.order});

  final PurchaseOrder order;

  @override
  State<_PurchaseExchangeDialog> createState() =>
      _PurchaseExchangeDialogState();
}

class _PurchaseExchangeDialogState extends State<_PurchaseExchangeDialog> {
  late final Map<int, double> _quantities = {
    for (final line in widget.order.lines) line.id: 0,
  };
  late final List<_PurchaseReplacementOption> _productOptions =
      _replacementOptionsFromOrderLines(widget.order.lines);
  late final List<_ReplacementLineEditor> _replacementEditors = [
    if (_productOptions.isNotEmpty)
      _ReplacementLineEditor(option: _productOptions.first),
  ];
  final TextEditingController _reasonController = TextEditingController();
  bool _showInputError = false;

  @override
  void dispose() {
    for (final editor in _replacementEditors) {
      editor.dispose();
    }
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final dialogWidth = (screenWidth - 48).clamp(280.0, 640.0).toDouble();
    final isCompact = dialogWidth < 520;
    final adjustmentOptions = _purchaseAdjustmentOptions(l10n, widget.order);

    return AlertDialog(
      icon: const Icon(Icons.swap_horiz_outlined),
      title: Text(l10n.purchaseExchangeTitle),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.purchaseExchangeOutboundSectionTitle,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              if (adjustmentOptions.isEmpty)
                Text(l10n.purchaseNoAdjustableItems)
              else
                for (final option in adjustmentOptions)
                  AdjustmentLineStepper(
                    option: option,
                    value: _quantities[option.lineId] ?? 0,
                    onChanged: (value) {
                      setState(() => _quantities[option.lineId] = value);
                    },
                  ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.purchaseExchangeReplacementSectionTitle,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _productOptions.isEmpty
                        ? null
                        : () {
                            setState(() {
                              _replacementEditors.add(
                                _ReplacementLineEditor(
                                  option: _productOptions.first,
                                ),
                              );
                            });
                          },
                    icon: const Icon(Icons.add),
                    label: Text(l10n.purchaseExchangeAddReplacementLine),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_productOptions.isEmpty)
                Text(l10n.purchaseExchangeNoReplacementProducts)
              else
                for (final (index, editor) in _replacementEditors.indexed)
                  _PurchaseReplacementLineInput(
                    editor: editor,
                    options: _productOptions,
                    isCompact: isCompact,
                    canRemove: _replacementEditors.length > 1,
                    onRemove: () {
                      setState(() {
                        _replacementEditors.removeAt(index).dispose();
                      });
                    },
                    onChanged: () => setState(() {}),
                  ),
              if (_showInputError) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.purchaseExchangeInvalidLinesError,
                  style: TextStyle(color: colors.danger),
                ),
              ],
              const SizedBox(height: 12),
              AdjustmentReasonField(
                controller: _reasonController,
                label: l10n.purchaseAdjustmentReasonLabel,
                hint: l10n.purchaseAdjustmentReasonHint,
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
        FilledButton(onPressed: _submit, child: Text(l10n.confirmButton)),
      ],
    );
  }

  void _submit() {
    final lines = _purchaseAdjustmentDrafts([
      for (final entry in _quantities.entries)
        if (entry.value > 0)
          AdjustmentLineSelection(lineId: entry.key, quantity: entry.value),
    ]);
    final replacementLines = <PurchaseReplacementLineDraft>[];
    for (final editor in _replacementEditors) {
      final quantity = int.tryParse(editor.quantityController.text.trim());
      final unitCost = double.tryParse(editor.unitCostController.text.trim());
      if (quantity == null ||
          unitCost == null ||
          quantity <= 0 ||
          unitCost < 0) {
        setState(() => _showInputError = true);
        return;
      }
      replacementLines.add(
        PurchaseReplacementLineDraft(
          variantId: editor.option.variantId,
          quantity: quantity,
          unitCost: unitCost,
        ),
      );
    }
    if (lines.isEmpty || replacementLines.isEmpty) {
      setState(() => _showInputError = true);
      return;
    }
    Navigator.of(context).pop(
      _PurchaseExchangeDialogResult(
        lines: lines,
        replacementLines: replacementLines,
        reason: _reasonController.text.trim(),
      ),
    );
  }
}

class _PurchaseReplacementLineInput extends StatelessWidget {
  const _PurchaseReplacementLineInput({
    required this.editor,
    required this.options,
    required this.isCompact,
    required this.canRemove,
    required this.onRemove,
    required this.onChanged,
  });

  final _ReplacementLineEditor editor;
  final List<_PurchaseReplacementOption> options;
  final bool isCompact;
  final bool canRemove;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final productField = DropdownButtonFormField<int>(
      value: editor.option.variantId,
      decoration: InputDecoration(
        labelText: l10n.purchaseExchangeReplacementProductLabel,
        isDense: true,
      ),
      items: [
        for (final option in options)
          DropdownMenuItem<int>(
            value: option.variantId,
            child: Text(
              option.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (variantId) {
        _PurchaseReplacementOption? selected;
        for (final option in options) {
          if (option.variantId == variantId) {
            selected = option;
            break;
          }
        }
        if (selected == null) {
          return;
        }
        editor.option = selected;
        editor.unitCostController.text = selected.unitCost.toStringAsFixed(2);
        onChanged();
      },
    );
    final quantityField = TextField(
      controller: editor.quantityController,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: l10n.purchaseExchangeReplacementQuantityLabel,
        isDense: true,
      ),
      onChanged: (_) => onChanged(),
    );
    final unitCostField = TextField(
      controller: editor.unitCostController,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: l10n.purchaseExchangeReplacementUnitCostLabel,
        isDense: true,
      ),
      onChanged: (_) => onChanged(),
    );
    final removeButton = IconButton(
      tooltip: l10n.removeOneTooltip,
      onPressed: canRemove ? onRemove : null,
      icon: const Icon(Icons.delete_outline),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: isCompact
          ? Column(
              children: [
                productField,
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: quantityField),
                    const SizedBox(width: 8),
                    Expanded(child: unitCostField),
                    removeButton,
                  ],
                ),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: productField),
                const SizedBox(width: 8),
                Expanded(child: quantityField),
                const SizedBox(width: 8),
                Expanded(child: unitCostField),
                removeButton,
              ],
            ),
    );
  }
}

class _PurchaseReplacementOption {
  const _PurchaseReplacementOption({
    required this.variantId,
    required this.label,
    required this.unitCost,
  });

  final int variantId;
  final String label;
  final double unitCost;
}

class _ReplacementLineEditor {
  _ReplacementLineEditor({required this.option})
    : quantityController = TextEditingController(text: '1'),
      unitCostController = TextEditingController(
        text: option.unitCost.toStringAsFixed(2),
      );

  _PurchaseReplacementOption option;
  final TextEditingController quantityController;
  final TextEditingController unitCostController;

  void dispose() {
    quantityController.dispose();
    unitCostController.dispose();
  }
}

List<_PurchaseReplacementOption> _replacementOptionsFromOrderLines(
  List<PurchaseOrderLine> lines,
) {
  final optionsByVariant = <int, _PurchaseReplacementOption>{};
  for (final line in lines) {
    optionsByVariant.putIfAbsent(line.variantId, () {
      final sku = line.variantSku;
      final name = line.displayName;
      final label = [
        if (name.isNotEmpty) name,
        if (sku != null && sku.isNotEmpty) sku,
      ].join(' • ');
      return _PurchaseReplacementOption(
        variantId: line.variantId,
        label: label.isEmpty ? '${line.variantId}' : label,
        unitCost: line.unitCost,
      );
    });
  }
  return optionsByVariant.values.toList(growable: false);
}

class _PurchaseExchangeDialogResult {
  const _PurchaseExchangeDialogResult({
    required this.lines,
    required this.replacementLines,
    required this.reason,
  });

  final List<PurchaseAdjustmentLineDraft> lines;
  final List<PurchaseReplacementLineDraft> replacementLines;
  final String reason;
}
