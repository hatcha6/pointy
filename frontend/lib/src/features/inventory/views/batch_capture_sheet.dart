import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/receipt_capture.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/units.dart';

/// The multi-lot intake sheet: which lots arrived, and how much of each.
///
/// Deliveries frequently bundle several production lots under one order line —
/// 60 boxes of Lot A and 40 of Lot B against one hundred ordered — so this
/// splits the line and counts the residual down to zero. A receipt whose lot
/// quantities do not add up to what was accepted is a receipt the backend
/// refuses, and it refuses it here first so the receiver finds out while the
/// boxes are still in front of them.
Future<List<ReceiptBatchCapture>?> showBatchCaptureSheet(
  BuildContext context, {
  required String productLabel,
  required double expectedQuantity,
  List<ReceiptBatchCapture> initial = const [],
  DateTime? suggestedExpiry,

  /// One lot for the whole line, no splitting. A serialised pack's lot is the
  /// header the scan loop's articles are born into, and the server gives every
  /// article on the line the first lot it is sent — a second row would be a
  /// lot that silently names nothing.
  bool singleLot = false,

  /// Every lot must say when it goes off — the product's `expiry_required`.
  /// The server refuses a receipt with an undated lot of such goods, so the
  /// sheet asks while the foil is still in the receiver's hand.
  bool expiryRequired = false,
}) {
  return showModalBottomSheet<List<ReceiptBatchCapture>>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) {
      return _BatchCaptureSheet(
        productLabel: productLabel,
        expectedQuantity: expectedQuantity,
        initial: initial,
        suggestedExpiry: suggestedExpiry,
        singleLot: singleLot,
        expiryRequired: expiryRequired,
      );
    },
  );
}

class _BatchCaptureSheet extends StatefulWidget {
  const _BatchCaptureSheet({
    required this.productLabel,
    required this.expectedQuantity,
    required this.initial,
    this.suggestedExpiry,
    this.singleLot = false,
    this.expiryRequired = false,
  });

  final String productLabel;
  final double expectedQuantity;
  final List<ReceiptBatchCapture> initial;
  final DateTime? suggestedExpiry;
  final bool singleLot;
  final bool expiryRequired;

  @override
  State<_BatchCaptureSheet> createState() => _BatchCaptureSheetState();
}

class _BatchCaptureSheetState extends State<_BatchCaptureSheet> {
  late List<ReceiptBatchCapture> _rows;

  /// Hands out a fresh identity per row. A lot row has no natural key while it
  /// is being typed — its code is blank until somebody fills it in — so the
  /// list is keyed on this instead of on the row number. With a positional key
  /// the editors are uncontrolled ``TextFormField``s seeded from
  /// ``initialValue``, so deleting the first of two lots left its code and
  /// quantity on screen over the lot that shifted up, and confirm submitted the
  /// one the receiver could no longer see.
  int _nextRowId = 0;
  final List<int> _rowIds = [];

  int _takeRowId() => _nextRowId++;

  @override
  void initState() {
    super.initState();
    final initial = widget.singleLot && widget.initial.length > 1
        ? [widget.initial.first.copyWith(quantity: widget.expectedQuantity)]
        : widget.initial;
    _rows = initial.isEmpty
        ? [
            ReceiptBatchCapture(
              quantity: widget.expectedQuantity,
              expiryDate: widget.suggestedExpiry,
            ),
          ]
        : List<ReceiptBatchCapture>.from(initial);
    _rowIds.addAll(List.generate(_rows.length, (_) => _takeRowId()));
  }

  double get _captured =>
      _rows.fold<double>(0, (sum, row) => sum + row.quantity);

  double get _residual => widget.expectedQuantity - _captured;

  bool get _canConfirm => _blockedReason(AppLocalizations.of(context)!).isEmpty;

  /// Why confirming is not possible yet, in the receiver's terms — or empty.
  String _blockedReason(AppLocalizations l10n) {
    if (_rows.any((row) => row.code.trim().isEmpty)) {
      return l10n.batchCaptureBlockedCode;
    }
    if (widget.expiryRequired && _rows.any((row) => row.expiryDate == null)) {
      return l10n.batchCaptureBlockedExpiry;
    }
    if (_residual.abs() >= 0.0005 || _rows.any((row) => row.quantity <= 0)) {
      return l10n.batchCaptureBlockedResidual(
        formatQuantity(_captured),
        formatQuantity(widget.expectedQuantity),
      );
    }
    return '';
  }

  void _addRow() {
    setState(() {
      _rowIds.add(_takeRowId());
      _rows = [
        ..._rows,
        ReceiptBatchCapture(
          // The rest of the line, so the common case — two lots, one split —
          // is one number typed rather than two.
          quantity: _residual > 0 ? _residual : 0,
          expiryDate: widget.suggestedExpiry,
        ),
      ];
    });
  }

  void _update(int index, ReceiptBatchCapture row) {
    setState(() {
      _rows = [..._rows];
      _rows[index] = row;
    });
  }

  void _removeAt(int index) {
    setState(() {
      _rowIds.removeAt(index);
      _rows = [..._rows]..removeAt(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.inventory_2_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.productLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(
                  l10n.batchCaptureProgress(
                    formatQuantity(_captured),
                    formatQuantity(widget.expectedQuantity),
                  ),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: _residual.abs() < 0.0005
                        ? colors.primaryStrong
                        : colors.warning,
                  ),
                ),
              ],
            ),
            const Divider(height: 16),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _rows.length,
                separatorBuilder: (_, _) => const Divider(height: 12),
                itemBuilder: (context, index) {
                  return _BatchRowEditor(
                    key: ValueKey('batch-row-${_rowIds[index]}'),
                    row: _rows[index],
                    expiryRequired: widget.expiryRequired,
                    canRemove: _rows.length > 1,
                    onChanged: (row) => _update(index, row),
                    onRemove: () => _removeAt(index),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            if (!widget.singleLot)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: _addRow,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.batchCaptureAddLot),
                ),
              ),
            const SizedBox(height: 4),
            if (!_canConfirm)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: colors.warning),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _blockedReason(l10n),
                        key: const ValueKey('batch-capture-blocked'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.cancelButton),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('batch-capture-confirm'),
                    onPressed: _canConfirm
                        ? () => Navigator.of(context).pop(_rows)
                        : null,
                    child: Text(l10n.batchCaptureConfirm),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BatchRowEditor extends StatelessWidget {
  const _BatchRowEditor({
    super.key,
    required this.row,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
    this.expiryRequired = false,
  });

  final ReceiptBatchCapture row;
  final bool expiryRequired;
  final bool canRemove;
  final ValueChanged<ReceiptBatchCapture> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              flex: 3,
              child: ScanWedgeTarget(
                child: TextFormField(
                  initialValue: row.code,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: l10n.batchCaptureLotCode,
                  ),
                  onChanged: (value) => onChanged(row.copyWith(code: value)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: TextFormField(
                initialValue: row.quantity > 0
                    ? formatQuantity(row.quantity)
                    : '',
                textAlign: TextAlign.center,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: l10n.batchCaptureQuantity,
                ),
                onChanged: (value) => onChanged(
                  row.copyWith(quantity: double.tryParse(value.trim()) ?? 0),
                ),
              ),
            ),
            if (canRemove)
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: onRemove,
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: _ExpiryField(
                label: expiryRequired
                    ? '${l10n.batchCaptureExpiry} *'
                    : l10n.batchCaptureExpiry,
                error: expiryRequired && row.expiryDate == null
                    ? l10n.batchCaptureExpiryRequired
                    : null,
                value: row.expiryDate,
                onChanged: (value) =>
                    onChanged(row.copyWith(expiryDate: value)),
              ),
            ),
            const SizedBox(width: 10),
            // Quick shortcuts, because a receiver reading a foil edge types the
            // same three or four horizons all day.
            for (final months in const [6, 12, 24, 36])
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 4),
                child: OutlinedButton(
                  onPressed: () => onChanged(
                    row.copyWith(expiryDate: _monthsFromNow(months)),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                  ),
                  child: Text(l10n.batchCaptureExpiryShortcut(months)),
                ),
              ),
          ],
        ),
      ],
    );
  }

  DateTime _monthsFromNow(int months) {
    final now = DateTime.now();
    final month = now.month + months;
    final year = now.year + (month - 1) ~/ 12;
    final normalizedMonth = (month - 1) % 12 + 1;
    // The last day of that month: a pack expires in a month, not on a day, and
    // the day on the foil is the last one.
    return DateTime(year, normalizedMonth + 1, 0);
  }
}

class _ExpiryField extends StatelessWidget {
  const _ExpiryField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.error,
  });

  final String label;
  final String? error;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? now,
          firstDate: DateTime(now.year - 5),
          lastDate: DateTime(now.year + 20),
        );
        if (picked != null) {
          onChanged(picked);
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          errorText: error,
        ),
        child: Text(
          value == null ? '—' : formatDate(value!),
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }
}
