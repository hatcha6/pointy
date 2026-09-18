import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/receipt_capture.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';

/// The scan-and-fill loop: N identifiers for N articles, counted down.
///
/// One widget, several callers — receiving today, counter purchase, consignment
/// intake, opening identification and serialized stock count later. That is why
/// it takes a count and a line cost rather than a purchase line: it knows
/// nothing about where the goods came from.
///
/// **It is a [ScanWedgeTarget], and that is not optional.** `ScanBurstGuard`
/// exists to stop a scanner's digits becoming a line quantity, and it does that
/// by rolling back any digit run typed faster than a human can type — which is
/// exactly what an IMEI scanned into this field looks like. Without the opt-out
/// the guard swallows the scan and the loop appears to simply not work,
/// intermittently, on whichever pane happens to hold focus.
Future<List<ReceiptUnitCapture>?> showUnitCaptureSheet(
  BuildContext context, {
  required String productLabel,
  required int expectedCount,
  required double lineUnitCost,
  List<ReceiptUnitCapture> initial = const [],
  bool allowCaptureLater = false,
}) {
  return showModalBottomSheet<List<ReceiptUnitCapture>>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) {
      return _UnitCaptureSheet(
        productLabel: productLabel,
        expectedCount: expectedCount,
        lineUnitCost: lineUnitCost,
        initial: initial,
        allowCaptureLater: allowCaptureLater,
      );
    },
  );
}

class _UnitCaptureSheet extends StatefulWidget {
  const _UnitCaptureSheet({
    required this.productLabel,
    required this.expectedCount,
    required this.lineUnitCost,
    required this.initial,
    required this.allowCaptureLater,
  });

  final String productLabel;
  final int expectedCount;
  final double lineUnitCost;
  final List<ReceiptUnitCapture> initial;
  final bool allowCaptureLater;

  @override
  State<_UnitCaptureSheet> createState() => _UnitCaptureSheetState();
}

class _UnitCaptureSheetState extends State<_UnitCaptureSheet> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  late List<ReceiptUnitCapture> _captured;
  bool _splitCosts = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _captured = List<ReceiptUnitCapture>.from(widget.initial);
    _splitCosts = _captured.any((unit) => unit.unitCost != null);
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  int get _remaining => widget.expectedCount - _captured.length;

  /// What is left to account for when the receiver is splitting the line's cost
  /// across individual articles. Shown live, and it has to reach zero — used
  /// goods have individual costs and a purchase line has one total, and letting
  /// the two disagree is how a cost figure becomes a fiction.
  double get _costResidual {
    final total = widget.lineUnitCost * widget.expectedCount;
    final assigned = _captured.fold<double>(
      0,
      (sum, unit) => sum + (unit.unitCost ?? 0),
    );
    return total - assigned;
  }

  void _add() {
    final code = _input.text.trim();
    final l10n = AppLocalizations.of(context)!;
    if (code.isEmpty) {
      return;
    }
    final normalized = _normalize(code);
    if (_captured.any((unit) => _normalize(unit.code) == normalized)) {
      setState(() => _error = l10n.unitCaptureDuplicate(code));
      _input.clear();
      return;
    }
    if (_remaining <= 0) {
      setState(() => _error = l10n.unitCaptureTooMany(widget.expectedCount));
      _input.clear();
      return;
    }
    setState(() {
      _captured = [
        ..._captured,
        ReceiptUnitCapture(
          code: code,
          unitCost: _splitCosts ? widget.lineUnitCost : null,
        ),
      ];
      _error = '';
    });
    _input.clear();
    // Straight back to the field: the receiver's next action is always another
    // scan, and reaching for the mouse forty times is the thing this loop
    // exists to avoid.
    _inputFocus.requestFocus();
  }

  String _normalize(String value) =>
      value.toUpperCase().replaceAll(RegExp(r'[\s\-._/]'), '');

  void _removeAt(int index) {
    setState(() {
      _captured = [..._captured]..removeAt(index);
      _error = '';
    });
  }

  void _setCost(int index, double? cost) {
    setState(() {
      _captured = [..._captured];
      _captured[index] = _captured[index].copyWith(unitCost: cost);
    });
  }

  void _toggleSplit(bool value) {
    setState(() {
      _splitCosts = value;
      _captured = _captured
          .map(
            (unit) =>
                unit.copyWith(unitCost: value ? widget.lineUnitCost : null),
          )
          .toList();
    });
  }

  bool get _canConfirm {
    if (_captured.length != widget.expectedCount) {
      return widget.allowCaptureLater;
    }
    if (!_splitCosts) {
      return true;
    }
    return _costResidual.abs() < 0.005;
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
                const Icon(Icons.qr_code_scanner_outlined),
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
                  l10n.unitCaptureProgress(
                    _captured.length,
                    widget.expectedCount,
                  ),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: _remaining == 0
                        ? colors.primaryStrong
                        : theme.hintColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ScanWedgeTarget(
              child: TextField(
                controller: _input,
                focusNode: _inputFocus,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.qr_code_2_outlined),
                  hintText: l10n.unitCaptureHint,
                  errorText: _error.isEmpty ? null : _error,
                ),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(height: 6),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _splitCosts,
              onChanged: _toggleSplit,
              title: Text(
                l10n.unitCaptureSplitCosts,
                style: theme.textTheme.bodyMedium,
              ),
              subtitle: _splitCosts
                  ? Text(
                      l10n.unitCaptureCostResidual(formatMoney(_costResidual)),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _costResidual.abs() < 0.005
                            ? colors.primaryStrong
                            : colors.warning,
                      ),
                    )
                  : null,
            ),
            const Divider(height: 12),
            Flexible(
              child: _captured.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        l10n.unitCaptureEmpty,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: _captured.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        return _CapturedUnitRow(
                          // Keyed by the identifier, not the row number. The
                          // cost box is an uncontrolled TextFormField seeded
                          // from initialValue, so with a positional key (or
                          // none) removing a row left the deleted unit's cost
                          // sitting over the one that shifted up.
                          key: ValueKey(_captured[index].code),
                          index: index,
                          unit: _captured[index],
                          showsCost: _splitCosts,
                          onRemove: () => _removeAt(index),
                          onCostChanged: (cost) => _setCost(index, cost),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
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
                    onPressed: _canConfirm
                        ? () => Navigator.of(context).pop(_captured)
                        : null,
                    child: Text(
                      _remaining > 0 && widget.allowCaptureLater
                          ? l10n.unitCaptureConfirmLater(_remaining)
                          : l10n.unitCaptureConfirm,
                    ),
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

class _CapturedUnitRow extends StatelessWidget {
  const _CapturedUnitRow({
    super.key,
    required this.index,
    required this.unit,
    required this.showsCost,
    required this.onRemove,
    required this.onCostChanged,
  });

  final int index;
  final ReceiptUnitCapture unit;
  final bool showsCost;
  final VoidCallback onRemove;
  final ValueChanged<double?> onCostChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.check_circle_outline, size: 18),
      title: Text(
        unit.code,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showsCost)
            SizedBox(
              width: 96,
              child: TextFormField(
                initialValue: unit.unitCost?.toStringAsFixed(2) ?? '',
                textAlign: TextAlign.center,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(isDense: true),
                onChanged: (value) =>
                    onCostChanged(double.tryParse(value.trim())),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
