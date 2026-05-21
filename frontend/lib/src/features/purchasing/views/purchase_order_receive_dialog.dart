part of 'purchase_order_details_screen.dart';

class _PurchaseReceiveDialog extends StatefulWidget {
  const _PurchaseReceiveDialog({required this.order});

  final PurchaseOrder order;

  @override
  State<_PurchaseReceiveDialog> createState() => _PurchaseReceiveDialogState();
}

class _PurchaseReceiveDialogState extends State<_PurchaseReceiveDialog> {
  late final List<PurchaseOrderLine> _receivableLines = widget.order.lines
      .where((line) => line.receivableQuantity > 0)
      .toList(growable: false);
  late final Map<int, TextEditingController> _receivedControllers = {
    for (final line in _receivableLines)
      line.id: TextEditingController(text: '${line.receivableQuantity}'),
  };
  late final Map<int, TextEditingController> _damagedControllers = {
    for (final line in _receivableLines)
      line.id: TextEditingController(text: '0'),
  };
  late final Map<int, TextEditingController> _rejectedControllers = {
    for (final line in _receivableLines)
      line.id: TextEditingController(text: '0'),
  };
  final TextEditingController _noteController = TextEditingController();
  bool _showQuantityError = false;

  @override
  void dispose() {
    for (final controller in _receivedControllers.values) {
      controller.dispose();
    }
    for (final controller in _damagedControllers.values) {
      controller.dispose();
    }
    for (final controller in _rejectedControllers.values) {
      controller.dispose();
    }
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      icon: const Icon(Icons.inventory_2_outlined),
      title: Text(l10n.purchaseReceiveTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_receivableLines.isEmpty)
                Text(l10n.purchaseReceiveNoOpenLines)
              else
                for (final line in _receivableLines)
                  _PurchaseReceiveLineInput(
                    line: line,
                    receivedController: _receivedControllers[line.id]!,
                    damagedController: _damagedControllers[line.id]!,
                    rejectedController: _rejectedControllers[line.id]!,
                    onChanged: () => setState(() {}),
                  ),
              if (_showQuantityError) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    l10n.purchaseReceiveInvalidQuantityError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _noteController,
                decoration: InputDecoration(
                  labelText: l10n.purchaseReceiveNoteLabel,
                  hintText: l10n.purchaseReceiveNoteHint,
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
          onPressed: _receivableLines.isEmpty ? null : _submit,
          child: Text(l10n.confirmButton),
        ),
      ],
    );
  }

  void _submit() {
    final lines = <PurchaseReceiveLineDraft>[];
    for (final line in _receivableLines) {
      final received = int.tryParse(_receivedControllers[line.id]!.text.trim());
      final damaged = int.tryParse(_damagedControllers[line.id]!.text.trim());
      final rejected = int.tryParse(_rejectedControllers[line.id]!.text.trim());
      if (received == null ||
          damaged == null ||
          rejected == null ||
          received < 0 ||
          damaged < 0 ||
          rejected < 0) {
        setState(() => _showQuantityError = true);
        return;
      }
      if (received > 0 || damaged > 0 || rejected > 0) {
        lines.add(
          PurchaseReceiveLineDraft(
            purchaseLineId: line.id,
            quantityReceived: received,
            quantityDamaged: damaged,
            quantityRejected: rejected,
          ),
        );
      }
    }
    if (lines.isEmpty) {
      setState(() => _showQuantityError = true);
      return;
    }
    Navigator.of(context).pop(
      _PurchaseReceiveDialogResult(
        lines: lines,
        note: _noteController.text.trim(),
      ),
    );
  }
}

class _PurchaseReceiveLineInput extends StatelessWidget {
  const _PurchaseReceiveLineInput({
    required this.line,
    required this.receivedController,
    required this.damagedController,
    required this.rejectedController,
    required this.onChanged,
  });

  final PurchaseOrderLine line;
  final TextEditingController receivedController;
  final TextEditingController damagedController;
  final TextEditingController rejectedController;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final received = int.tryParse(receivedController.text.trim()) ?? 0;
    final damaged = int.tryParse(damagedController.text.trim()) ?? 0;
    final rejected = int.tryParse(rejectedController.text.trim()) ?? 0;
    final afterDelivered =
        line.receivedQuantity + line.damagedQuantity + received + damaged;
    final afterOpen = line.receivableQuantity - received - damaged - rejected;
    final afterVariance = afterDelivered - line.quantity;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            line.displayName.isEmpty
                ? l10n.purchaseOrderUnknownProduct
                : line.displayName,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (line.productSku != null && line.productSku!.isNotEmpty)
                line.productSku!,
              l10n.purchaseReceiveExpectedValue(line.quantity),
              l10n.purchaseReceiveAlreadyValue(line.receivedQuantity),
              l10n.purchaseReceiveOpenValue(line.receivableQuantity),
              if (line.damagedQuantity > 0)
                l10n.purchaseLineDamagedQuantity(line.damagedQuantity),
              if (line.rejectedQuantity > 0)
                l10n.purchaseLineRejectedQuantity(line.rejectedQuantity),
              l10n.purchaseReceiveOpenAfterValue(afterOpen < 0 ? 0 : afterOpen),
              l10n.purchaseReceiveAfterVarianceValue(
                _formatSignedInt(afterVariance),
              ),
            ].join(' • '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: receivedController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.purchaseReceiveReceivedLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: damagedController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.purchaseReceiveDamagedLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: rejectedController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.purchaseReceiveRejectedLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PurchaseReceiveDialogResult {
  const _PurchaseReceiveDialogResult({required this.lines, required this.note});

  final List<PurchaseReceiveLineDraft> lines;
  final String note;
}
