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
      line.id: TextEditingController(
        text: formatQuantity(line.receivableQuantity),
      ),
  };
  late final Map<int, TextEditingController> _damagedControllers = {
    for (final line in _receivableLines)
      line.id: TextEditingController(text: '0'),
  };
  late final Map<int, TextEditingController> _rejectedControllers = {
    for (final line in _receivableLines)
      line.id: TextEditingController(text: '0'),
  };
  late final Map<int, TextEditingController> _expiryControllers = {
    for (final line in _receivableLines)
      if (line.tracksExpiry)
        line.id: TextEditingController(
          text: _formatReceiveDate(line.expiryDate),
        ),
  };
  final TextEditingController _noteController = TextEditingController();
  bool _showQuantityError = false;
  bool _showExpiryError = false;

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
    for (final controller in _expiryControllers.values) {
      controller.dispose();
    }
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

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
                    expiryController: _expiryControllers[line.id],
                    onChanged: () => setState(() {
                      _showQuantityError = false;
                      _showExpiryError = false;
                    }),
                  ),
              if (_showQuantityError) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    l10n.purchaseReceiveInvalidQuantityError,
                    style: TextStyle(color: colors.danger),
                  ),
                ),
              ],
              if (_showExpiryError) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    l10n.purchaseLineExpiryDateRequired,
                    style: TextStyle(color: colors.danger),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _noteController,
                decoration: InputDecoration(
                  labelText: l10n.purchaseReceiveNoteLabel,
                  hintText: l10n.purchaseReceiveNoteHint,
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
        TutorTarget(
          anchor: TutorAnchor.purchaseReceiveConfirmButton,
          child: FilledButton(
            onPressed: _receivableLines.isEmpty ? null : _submit,
            child: Text(l10n.confirmButton),
          ),
        ),
      ],
    );
  }

  void _submit() {
    final lines = <PurchaseReceiveLineDraft>[];
    for (final line in _receivableLines) {
      final received = double.tryParse(
        _receivedControllers[line.id]!.text.trim(),
      );
      final damaged = double.tryParse(
        _damagedControllers[line.id]!.text.trim(),
      );
      final rejected = double.tryParse(
        _rejectedControllers[line.id]!.text.trim(),
      );
      if (received == null ||
          damaged == null ||
          rejected == null ||
          received < 0 ||
          damaged < 0 ||
          rejected < 0) {
        setState(() => _showQuantityError = true);
        return;
      }
      DateTime? expiryDate;
      if (line.tracksExpiry && received > 0) {
        final expiryText = _expiryControllers[line.id]!.text.trim();
        expiryDate = _parseReceiveDate(expiryText);
        if (expiryDate == null) {
          setState(() => _showExpiryError = true);
          return;
        }
      }
      if (received > 0 || damaged > 0 || rejected > 0) {
        lines.add(
          PurchaseReceiveLineDraft(
            purchaseLineId: line.id,
            quantityReceived: received,
            quantityDamaged: damaged,
            quantityRejected: rejected,
            expiryDate: expiryDate,
          ),
        );
      }
    }
    if (lines.isEmpty) {
      setState(() => _showQuantityError = true);
      return;
    }
    _showQuantityError = false;
    _showExpiryError = false;
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
    this.expiryController,
    required this.onChanged,
  });

  final PurchaseOrderLine line;
  final TextEditingController receivedController;
  final TextEditingController damagedController;
  final TextEditingController rejectedController;
  final TextEditingController? expiryController;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final received = double.tryParse(receivedController.text.trim()) ?? 0;
    final damaged = double.tryParse(damagedController.text.trim()) ?? 0;
    final rejected = double.tryParse(rejectedController.text.trim()) ?? 0;
    final afterDelivered =
        line.receivedQuantity + line.damagedQuantity + received + damaged;
    final afterOpen = line.receivableQuantity - received - damaged - rejected;
    final afterVariance = afterDelivered - line.quantity;
    final expiryController = this.expiryController;
    final expiryText = expiryController?.text.trim() ?? '';
    final expiryInvalid =
        line.tracksExpiry &&
        received > 0 &&
        _parseReceiveDate(expiryText) == null;

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
              if (line.variantSku != null && line.variantSku!.isNotEmpty)
                line.variantSku!,
              l10n.purchaseReceiveExpectedValue(formatQuantity(line.quantity)),
              l10n.purchaseReceiveAlreadyValue(
                formatQuantity(line.receivedQuantity),
              ),
              l10n.purchaseReceiveOpenValue(
                formatQuantity(line.receivableQuantity),
              ),
              if (line.damagedQuantity > 0)
                l10n.purchaseLineDamagedQuantity(
                  formatQuantity(line.damagedQuantity),
                ),
              if (line.rejectedQuantity > 0)
                l10n.purchaseLineRejectedQuantity(
                  formatQuantity(line.rejectedQuantity),
                ),
              l10n.purchaseReceiveOpenAfterValue(
                formatQuantity(afterOpen < 0 ? 0 : afterOpen),
              ),
              l10n.purchaseReceiveAfterVarianceValue(
                _formatSignedQuantityValue(afterVariance),
              ),
            ].join(' • '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TutorTarget(
                  anchor: TutorAnchor.purchaseReceiveQuantityField,
                  // A delivery that came up short is the point of the lesson,
                  // so the step has to name the line that is short.
                  id: line.variantSku,
                  child: TextField(
                    controller: receivedController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: l10n.purchaseReceiveReceivedLabel,
                      isDense: true,
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: damagedController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: l10n.purchaseReceiveDamagedLabel,
                    isDense: true,
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: rejectedController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: l10n.purchaseReceiveRejectedLabel,
                    isDense: true,
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
            ],
          ),
          if (line.tracksExpiry && expiryController != null) ...[
            const SizedBox(height: 8),
            TextField(
              controller: expiryController,
              keyboardType: TextInputType.datetime,
              inputFormatters: const [_ReceiveDateDashInputFormatter()],
              decoration: InputDecoration(
                labelText: l10n.purchaseLineExpiryDateLabel,
                hintText: l10n.purchaseLineExpiryDateHint,
                isDense: true,
                prefixIcon: const Icon(Icons.event_busy_outlined),
                suffixIcon: IconButton(
                  tooltip: l10n.purchaseLineExpiryDatePickerTooltip,
                  onPressed: () => _pickExpiryDate(context),
                  icon: const Icon(Icons.calendar_month_outlined),
                ),
                errorText: expiryInvalid
                    ? l10n.purchaseLineExpiryDateInvalid
                    : null,
              ),
              onChanged: (_) => onChanged(),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _pickExpiryDate(BuildContext context) async {
    final controller = expiryController;
    if (controller == null) {
      return;
    }
    final parsed = _parseReceiveDate(controller.text.trim());
    final current = parsed ?? line.expiryDate ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected == null || !context.mounted) {
      return;
    }
    controller.text = _formatReceiveDate(selected);
    onChanged();
  }
}

class _PurchaseReceiveDialogResult {
  const _PurchaseReceiveDialogResult({required this.lines, required this.note});

  final List<PurchaseReceiveLineDraft> lines;
  final String note;
}

String _formatReceiveDate(DateTime? date) {
  if (date == null) {
    return '';
  }
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

DateTime? _parseReceiveDate(String text) {
  if (text.length != 10) {
    return null;
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null) {
    return null;
  }
  final date = DateTime(parsed.year, parsed.month, parsed.day);
  return _formatReceiveDate(date) == text ? date : null;
}

class _ReceiveDateDashInputFormatter extends TextInputFormatter {
  const _ReceiveDateDashInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final limited = digits.length > 8 ? digits.substring(0, 8) : digits;
    final buffer = StringBuffer();
    for (var index = 0; index < limited.length; index += 1) {
      if (index == 4 || index == 6) {
        buffer.write('-');
      }
      buffer.write(limited[index]);
    }
    final text = buffer.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
