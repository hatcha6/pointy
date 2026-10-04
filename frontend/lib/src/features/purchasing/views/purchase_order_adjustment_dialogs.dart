part of 'purchase_order_details_screen.dart';

/// Maps a purchase order's adjustable lines onto the shared
/// [AdjustmentLineOption] shape used by [showQuantityAdjustmentDialog] and the
/// exchange dialog's outbound section. A purchase quantity may be fractional
/// (the buyer's choice), so the options allow tap-to-type decimal entry.
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
            // A carton line is counted and priced by the carton; saying "per
            // piece" next to a carton's price is how 48.00 a carton reads as
            // 48.00 a bottle.
            if (_isPackLine(line)) ...[
              l10n.purchaseOrderLineQuantity(
                '${formatQuantity(line.quantity)} ${line.unitLabel}',
              ),
              l10n.purchaseAdjustmentUnitPricePer(
                formatMoney(line.unitCost),
                line.unitLabel,
              ),
            ] else ...[
              l10n.purchaseOrderLineQuantity(formatQuantity(line.quantity)),
              l10n.unitPriceEach(formatMoney(line.unitCost)),
            ],
            l10n.purchaseAdjustmentLineRemaining(
              formatQuantity(line.adjustableQuantity),
              formatQuantity(line.quantity),
            ),
            // A handset goes back by name, and the sheet after this asks which.
            if (line.trackingMode.tracksUnits)
              l10n.purchaseAdjustmentUnitsPickNext,
          ].join(' • '),
          maxQuantity: line.adjustableQuantity,
          // Handsets go back whole; everything else may go back by a fraction.
          allowDecimal: !line.trackingMode.tracksUnits,
          decimalEntryTitle: l10n.posUnitQuantityLabel,
        ),
  ];
}

/// Bought in a unit bigger than one item — a carton of 24 — with a label to
/// say so.
bool _isPackLine(PurchaseOrderLine line) =>
    line.baseFactor != 1 && line.unitLabel.isNotEmpty;

/// Names the handsets behind every serialised line in [drafts].
///
/// The server refuses a serial line that names none — it will not guess which
/// IMEI went back — so the buyer picks them here, from what is standing where
/// the delivery landed. Lot and quantity lines pass through untouched: the
/// earliest-expiring lot goes first. Null when the buyer backs out.
Future<List<PurchaseAdjustmentLineDraft>?> _pickReturnedUnits(
  BuildContext context,
  PurchaseOrderDetailsViewModel viewModel,
  List<PurchaseAdjustmentLineDraft> drafts,
) async {
  final l10n = AppLocalizations.of(context)!;
  final linesById = {for (final line in viewModel.order.lines) line.id: line};
  final pickLines = <UnitPickLine>[];
  for (final draft in drafts) {
    final line = linesById[draft.lineId];
    if (line == null || !line.trackingMode.tracksUnits) {
      continue;
    }
    // Counted in articles: a box of three handsets is three to name.
    final count = line.toBaseQuantity(draft.quantity);
    if ((count - count.round()).abs() > 0.0001) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.purchaseAdjustmentUnitsWholeOnly)),
        );
      return null;
    }
    pickLines.add(
      UnitPickLine(
        key: line.id,
        title: line.displayName.isEmpty
            ? l10n.purchaseOrderUnknownProduct
            : line.displayName,
        count: count.round(),
        variantId: line.variantId,
      ),
    );
  }
  if (pickLines.isEmpty) {
    return drafts;
  }
  final picks = await showUnitPickSheet(
    context,
    title: l10n.purchaseAdjustmentUnitsTitle,
    message: l10n.purchaseAdjustmentUnitsBody,
    confirmLabel: l10n.confirmButton,
    lines: pickLines,
    loadUnits: viewModel.loadReturnableUnits,
  );
  if (picks == null) {
    return null;
  }
  return [
    for (final draft in drafts)
      if (picks[draft.lineId] case final unitIds?)
        draft.copyWith(unitIds: unitIds)
      else
        draft,
  ];
}

/// Converts the shared dialog's selections back into purchasing's draft model
/// (quantities may be fractional for fractional units).
List<PurchaseAdjustmentLineDraft> _purchaseAdjustmentDrafts(
  List<AdjustmentLineSelection> selections,
) {
  return [
    for (final selection in selections)
      PurchaseAdjustmentLineDraft(
        lineId: selection.lineId,
        quantity: selection.quantity,
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

  /// Mirrors of what goes out, one per product, plus whatever the buyer added.
  /// Empty until something is chosen to go out.
  final List<_ReplacementLineEditor> _replacementEditors = [];
  final TextEditingController _reasonController = TextEditingController();
  bool _showInputError = false;
  bool _showLotError = false;

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
                      setState(() {
                        _quantities[option.lineId] = value;
                        _followOutbound();
                      });
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
              // A replacement is keyed by product alone, so the server counts
              // it in single items. Said only where it could be misread: an
              // order bought by the carton.
              if (widget.order.lines.any(_isPackLine))
                Text(
                  l10n.purchaseExchangeReplacementBaseUnitHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 8),
              if (_productOptions.isEmpty)
                Text(l10n.purchaseExchangeNoReplacementProducts)
              else if (_replacementEditors.isEmpty)
                Text(
                  l10n.purchaseExchangeReplacementMirrorHint,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                )
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
                    onCapture: () => _captureReplacement(editor),
                  ),
              if (_showInputError) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.purchaseExchangeInvalidLinesError,
                  style: TextStyle(color: colors.danger),
                ),
              ],
              if (_showLotError) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.purchaseAdjustmentUnitsReplacementLotRequired,
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

  /// What goes out of each product, in single items and what they cost after
  /// discounts — the like-for-like replacement the server builds itself when
  /// none is sent (`_like_for_like_replacement`).
  Map<int, _OutboundMirror> _outboundMirrors() {
    final quantities = <int, double>{};
    final values = <int, double>{};
    for (final line in widget.order.lines) {
      final quantity = _quantities[line.id] ?? 0;
      if (quantity <= 0) {
        continue;
      }
      quantities[line.variantId] =
          (quantities[line.variantId] ?? 0) + line.toBaseQuantity(quantity);
      values[line.variantId] =
          (values[line.variantId] ?? 0) +
          quantity * (line.netUnitCost ?? line.unitCost);
    }
    return {
      for (final MapEntry(key: variantId, value: quantity)
          in quantities.entries)
        if (quantity > 0)
          variantId: _OutboundMirror(
            quantity: quantity,
            unitCost: (values[variantId] ?? 0) / quantity,
          ),
    };
  }

  /// Keep the untouched replacement rows equal to what goes out: add one when
  /// a product starts going out, follow its quantity, drop it when it stops.
  /// A row the buyer has edited is theirs and is left alone.
  void _followOutbound() {
    final mirrors = _outboundMirrors();
    final dropped = _replacementEditors
        .where(
          (editor) =>
              editor.followsOutbound &&
              !mirrors.containsKey(editor.option.variantId),
        )
        .toList();
    _replacementEditors.removeWhere(dropped.contains);
    for (final MapEntry(key: variantId, value: mirror) in mirrors.entries) {
      final rows = _replacementEditors
          .where((editor) => editor.option.variantId == variantId)
          .toList();
      if (rows.isEmpty) {
        final option = _productOptions
            .where((option) => option.variantId == variantId)
            .firstOrNull;
        if (option != null) {
          _replacementEditors.add(
            _ReplacementLineEditor.mirroring(option, mirror),
          );
        }
        continue;
      }
      for (final row in rows.where((row) => row.followsOutbound)) {
        row.mirror(mirror);
      }
    }
    // Disposed after the frame that stops building their fields.
    if (dropped.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final editor in dropped) {
          editor.dispose();
        }
      });
    }
  }

  /// Scan what the supplier sent back, exactly as a receipt scans it. Seeded
  /// with the row's quantity, which for a replacement is already in articles.
  Future<void> _captureReplacement(_ReplacementLineEditor editor) async {
    final mode = editor.option.trackingMode;
    final quantity = double.tryParse(editor.quantityController.text.trim());
    if (quantity == null || quantity <= 0) {
      setState(() => _showInputError = true);
      return;
    }
    final unitCost =
        double.tryParse(editor.unitCostController.text.trim()) ??
        editor.option.unitCost;
    var batches = editor.capture?.batches ?? const <ReceiptBatchCapture>[];
    if (mode.tracksLots) {
      final captured = await showBatchCaptureSheet(
        context,
        productLabel: editor.option.label,
        expectedQuantity: quantity,
        initial: batches,
        singleLot: mode.tracksUnits,
      );
      if (captured == null || !mounted) {
        return;
      }
      batches = captured;
    }
    var units = editor.capture?.units ?? const <ReceiptUnitCapture>[];
    if (mode.tracksUnits) {
      final captured = await showUnitCaptureSheet(
        context,
        productLabel: editor.option.label,
        expectedCount: quantity.round(),
        lineUnitCost: unitCost,
        initial: units,
        // A replacement nobody scanned is counted and waits on the
        // missing-identifier list, which is what the server does with it.
        allowCaptureLater: true,
        // It is worth what the shelf says, so a cost per handset is not asked.
        allowSplitCosts: false,
      );
      if (captured == null || !mounted) {
        return;
      }
      units = captured;
    }
    setState(() {
      editor.capture = ReceiptLineCapture(units: units, batches: batches);
      _showLotError = false;
    });
  }

  void _submit() {
    final lines = _purchaseAdjustmentDrafts([
      for (final entry in _quantities.entries)
        if (entry.value > 0)
          AdjustmentLineSelection(lineId: entry.key, quantity: entry.value),
    ]);
    final replacementLines = <PurchaseReplacementLineDraft>[];
    for (final editor in _replacementEditors) {
      final quantity = double.tryParse(editor.quantityController.text.trim());
      final unitCost = double.tryParse(editor.unitCostController.text.trim());
      if (quantity == null ||
          unitCost == null ||
          quantity <= 0 ||
          unitCost < 0) {
        setState(() => _showInputError = true);
        return;
      }
      final mode = editor.option.trackingMode;
      if (mode.tracksUnits && quantity != quantity.roundToDouble()) {
        setState(() => _showInputError = true);
        return;
      }
      // The server mints a lot for a batch replacement nobody named, but a
      // serialised pack is born into its lot: without one it is refused.
      if (mode.requiresLot && (editor.capture?.batches.isEmpty ?? true)) {
        setState(() => _showLotError = true);
        return;
      }
      replacementLines.add(
        PurchaseReplacementLineDraft(
          variantId: editor.option.variantId,
          quantity: quantity,
          unitCost: unitCost,
          capture: editor.capture,
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
    required this.onCapture,
  });

  final _ReplacementLineEditor editor;
  final List<_PurchaseReplacementOption> options;
  final bool isCompact;
  final bool canRemove;
  final VoidCallback onRemove;
  final VoidCallback onChanged;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final productField = DropdownButtonFormField<int>(
      initialValue: editor.option.variantId,
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
        editor.capture = null;
        editor.followsOutbound = false;
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
      onChanged: (_) {
        // Scans counted for the old quantity no longer add up.
        editor.capture = null;
        editor.followsOutbound = false;
        onChanged();
      },
    );
    final unitCostField = TextField(
      controller: editor.unitCostController,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: l10n.purchaseExchangeReplacementUnitCostLabel,
        isDense: true,
      ),
      onChanged: (_) {
        editor.followsOutbound = false;
        onChanged();
      },
    );
    final removeButton = IconButton(
      tooltip: l10n.removeOneTooltip,
      onPressed: canRemove ? onRemove : null,
      icon: const Icon(Icons.delete_outline),
    );
    final captured = editor.capture != null && !editor.capture!.isEmpty;
    final captureButton = editor.option.trackingMode.isTracked
        ? IconButton(
            tooltip: captured
                ? l10n.purchaseAdjustmentUnitsReplacementScanned
                : l10n.purchaseAdjustmentUnitsScanReplacement,
            onPressed: onCapture,
            icon: Icon(
              captured
                  ? Icons.check_circle_outline
                  : Icons.qr_code_scanner_outlined,
            ),
          )
        : null;

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
                    ?captureButton,
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
                ?captureButton,
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
    this.trackingMode = TrackingMode.quantity,
  });

  final int variantId;
  final String label;

  /// What one single item cost after discounts. Per base unit, because that
  /// is how the server reads a replacement: it carries no purchase unit, so a
  /// carton's price here would value every bottle at a carton.
  final double unitCost;

  /// Whether what arrives has to be scanned: handsets by number, lots by code.
  final TrackingMode trackingMode;
}

class _ReplacementLineEditor {
  _ReplacementLineEditor({required this.option})
    : followsOutbound = false,
      quantityController = TextEditingController(text: '1'),
      unitCostController = TextEditingController(
        text: option.unitCost.toStringAsFixed(2),
      );

  _ReplacementLineEditor.mirroring(this.option, _OutboundMirror mirror)
    : followsOutbound = true,
      quantityController = TextEditingController(
        text: formatQuantity(mirror.quantity),
      ),
      unitCostController = TextEditingController(
        text: mirror.unitCost.toStringAsFixed(2),
      );

  _PurchaseReplacementOption option;
  final TextEditingController quantityController;
  final TextEditingController unitCostController;

  /// What the receiver scanned for this replacement, if anything.
  ReceiptLineCapture? capture;

  /// Still the like-for-like mirror of what goes out: it follows the outbound
  /// quantities until the buyer edits it, and goes when they go.
  bool followsOutbound;

  void mirror(_OutboundMirror mirror) {
    final quantity = formatQuantity(mirror.quantity);
    if (quantityController.text != quantity) {
      quantityController.text = quantity;
      // Scans counted for the old quantity no longer add up.
      capture = null;
    }
    unitCostController.text = mirror.unitCost.toStringAsFixed(2);
  }

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
        unitCost: (line.netUnitCost ?? line.unitCost) / line.baseFactor,
        trackingMode: line.trackingMode,
      );
    });
  }
  return optionsByVariant.values.toList(growable: false);
}

/// What goes out of one product, in single items, and what one cost.
class _OutboundMirror {
  const _OutboundMirror({required this.quantity, required this.unitCost});

  final double quantity;
  final double unitCost;
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
