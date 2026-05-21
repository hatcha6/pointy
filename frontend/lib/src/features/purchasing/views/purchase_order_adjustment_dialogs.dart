part of 'purchase_order_details_screen.dart';

class _PurchaseAdjustmentDialog extends StatefulWidget {
  const _PurchaseAdjustmentDialog({
    required this.title,
    required this.icon,
    required this.order,
  });

  final String title;
  final IconData icon;
  final PurchaseOrder order;

  @override
  State<_PurchaseAdjustmentDialog> createState() =>
      _PurchaseAdjustmentDialogState();
}

class _PurchaseAdjustmentDialogState extends State<_PurchaseAdjustmentDialog> {
  late final Map<int, int> _quantities = {
    for (final line in widget.order.lines) line.id: 0,
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
    final adjustableLines = widget.order.lines
        .where((line) => line.adjustableQuantity > 0)
        .toList(growable: false);

    return AlertDialog(
      icon: Icon(widget.icon),
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (adjustableLines.isEmpty)
                Text(l10n.purchaseNoAdjustableItems)
              else
                for (final line in adjustableLines)
                  _PurchaseAdjustmentLineStepper(
                    line: line,
                    value: _quantities[line.id] ?? 0,
                    onChanged: (value) {
                      setState(() => _quantities[line.id] = value);
                    },
                  ),
              const SizedBox(height: 12),
              TextField(
                controller: _reasonController,
                decoration: InputDecoration(
                  labelText: l10n.purchaseAdjustmentReasonLabel,
                  hintText: l10n.purchaseAdjustmentReasonHint,
                  border: const OutlineInputBorder(),
                ),
                maxLines: 2,
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
            final lines = [
              for (final line in adjustableLines)
                if ((_quantities[line.id] ?? 0) > 0)
                  PurchaseAdjustmentLineDraft(
                    lineId: line.id,
                    quantity: _quantities[line.id]!,
                  ),
            ];
            Navigator.of(context).pop(
              _PurchaseAdjustmentDialogResult(
                lines: lines,
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

class _PurchaseExchangeDialog extends StatefulWidget {
  const _PurchaseExchangeDialog({required this.order});

  final PurchaseOrder order;

  @override
  State<_PurchaseExchangeDialog> createState() =>
      _PurchaseExchangeDialogState();
}

class _PurchaseExchangeDialogState extends State<_PurchaseExchangeDialog> {
  late final List<PurchaseOrderLine> _adjustableLines = widget.order.lines
      .where((line) => line.adjustableQuantity > 0)
      .toList(growable: false);
  late final Map<int, int> _quantities = {
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
    final screenWidth = MediaQuery.sizeOf(context).width;
    final dialogWidth = (screenWidth - 48).clamp(280.0, 640.0).toDouble();
    final isCompact = dialogWidth < 520;

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
              if (_adjustableLines.isEmpty)
                Text(l10n.purchaseNoAdjustableItems)
              else
                for (final line in _adjustableLines)
                  _PurchaseAdjustmentLineStepper(
                    line: line,
                    value: _quantities[line.id] ?? 0,
                    onChanged: (value) {
                      setState(() => _quantities[line.id] = value);
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
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _reasonController,
                decoration: InputDecoration(
                  labelText: l10n.purchaseAdjustmentReasonLabel,
                  hintText: l10n.purchaseAdjustmentReasonHint,
                  border: const OutlineInputBorder(),
                ),
                maxLines: 2,
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
    final lines = [
      for (final line in _adjustableLines)
        if ((_quantities[line.id] ?? 0) > 0)
          PurchaseAdjustmentLineDraft(
            lineId: line.id,
            quantity: _quantities[line.id]!,
          ),
    ];
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
      initialValue: editor.option.variantId,
      decoration: InputDecoration(
        labelText: l10n.purchaseExchangeReplacementProductLabel,
        border: const OutlineInputBorder(),
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
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (_) => onChanged(),
    );
    final unitCostField = TextField(
      controller: editor.unitCostController,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: l10n.purchaseExchangeReplacementUnitCostLabel,
        border: const OutlineInputBorder(),
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
      final sku = line.productSku;
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

class _PurchaseAdjustmentLineStepper extends StatelessWidget {
  const _PurchaseAdjustmentLineStepper({
    required this.line,
    required this.value,
    required this.onChanged,
  });

  final PurchaseOrderLine line;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        line.displayName.isEmpty
            ? l10n.purchaseOrderUnknownProduct
            : line.displayName,
      ),
      subtitle: Text(
        [
          l10n.purchaseOrderLineQuantity(line.quantity),
          l10n.unitPriceEach(formatMoney(line.unitCost)),
          l10n.purchaseAdjustmentLineRemaining(
            line.adjustableQuantity,
            line.quantity,
          ),
        ].join(' • '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l10n.removeOneTooltip,
            onPressed: value <= 0 ? null : () => onChanged(value - 1),
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 32,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: l10n.addOneTooltip,
            onPressed: value >= line.adjustableQuantity
                ? null
                : () => onChanged(value + 1),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

class _PurchaseAdjustmentDialogResult {
  const _PurchaseAdjustmentDialogResult({
    required this.lines,
    required this.reason,
  });

  final List<PurchaseAdjustmentLineDraft> lines;
  final String reason;
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
