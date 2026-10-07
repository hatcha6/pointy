import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/barcode_label.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/services/barcode_label_print_preferences.dart';
import '../../../shared/design/design.dart';
import '../../../shared/printing/print_paper_mismatch_message.dart';

/// One row of a label batch: a group of handsets (one sticker each, their own
/// numbers) or one lot (a count of stickers carrying its date).
class LabelBatchEntry {
  const LabelBatchEntry({
    required this.title,
    required this.subtitle,
    required this.lines,
    this.copiesEditable = false,
  });

  final String title;
  final String subtitle;

  /// What prints. A handset group holds one line per handset; a lot holds one
  /// line whose copies the person may change ([copiesEditable]).
  final List<BarcodeLabelPrintLine> lines;
  final bool copiesEditable;

  /// A sticker without a barcode would be a sticker the till cannot scan.
  bool get printable =>
      lines.isNotEmpty &&
      lines.every((line) => line.label.barcode.trim().isNotEmpty);

  int get stickerCount => lines.fold(0, (sum, line) => sum + line.copies);
}

/// Prints a batch of labels in one go — the handsets ticked in a list, or
/// everything a delivery just brought — after the person sees what and how
/// many. One print job, one result, one snackbar.
Future<void> showLabelBatchPrintSheet(
  BuildContext context, {
  required String title,
  String subtitle = '',
  required List<LabelBatchEntry> entries,
  required PrintingRepository printingRepository,
}) {
  final messenger = ScaffoldMessenger.of(context);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => _LabelBatchPrintSheet(
      title: title,
      subtitle: subtitle,
      entries: entries,
      printingRepository: printingRepository,
      messenger: messenger,
    ),
  );
}

class _LabelBatchPrintSheet extends StatefulWidget {
  const _LabelBatchPrintSheet({
    required this.title,
    required this.subtitle,
    required this.entries,
    required this.printingRepository,
    required this.messenger,
  });

  final String title;
  final String subtitle;
  final List<LabelBatchEntry> entries;
  final PrintingRepository printingRepository;
  final ScaffoldMessengerState messenger;

  @override
  State<_LabelBatchPrintSheet> createState() => _LabelBatchPrintSheetState();
}

class _LabelBatchPrintSheetState extends State<_LabelBatchPrintSheet> {
  late final Set<int> _selected = {
    for (var index = 0; index < widget.entries.length; index++)
      if (widget.entries[index].printable) index,
  };
  late final List<int> _copies = [
    for (final entry in widget.entries) entry.stickerCount,
  ];
  bool _includePrice = true;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadIncludePrice());
  }

  Future<void> _loadIncludePrice() async {
    final remembered = await barcodeLabelPrintPreferences.includePrice();
    if (mounted && remembered != _includePrice) {
      setState(() => _includePrice = remembered);
    }
  }

  int get _total => [
    for (final index in _selected) _copies[index],
  ].fold(0, (sum, count) => sum + count);

  List<BarcodeLabelPrintLine> _lines() {
    return [
      for (final index in _selected.toList()..sort())
        for (final line in widget.entries[index].lines)
          BarcodeLabelPrintLine(
            label: line.label,
            copies: widget.entries[index].copiesEditable
                ? _copies[index]
                : line.copies,
            includePrice: _includePrice && line.label.unitPrice > 0,
            expiryDate: line.expiryDate,
            caption: line.caption,
          ),
    ];
  }

  Future<void> _print() async {
    final l10n = AppLocalizations.of(context)!;
    final total = _total;
    setState(() => _printing = true);
    unawaited(barcodeLabelPrintPreferences.setIncludePrice(_includePrice));
    final result = await widget.printingRepository.printBarcodeLabels(_lines());
    if (!mounted) return;
    Navigator.of(context).pop();
    final mismatch = result.paperMismatch;
    widget.messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            mismatch != null
                ? printPaperMismatchMessage(l10n, mismatch)
                : result.isSuccess
                ? l10n.barcodeLabelPrintSuccess(total)
                : result.unassignedRole != null
                ? l10n.barcodeLabelNoPrinter
                : l10n.barcodeLabelPrintError,
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.print_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Text(widget.title, style: theme.textTheme.titleMedium),
              ),
            ],
          ),
          if (widget.subtitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              widget.subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: widget.entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) => _EntryRow(
                key: ValueKey('label-batch-entry-$index'),
                entry: widget.entries[index],
                selected: _selected.contains(index),
                copies: _copies[index],
                onSelected: (value) => setState(() {
                  value ? _selected.add(index) : _selected.remove(index);
                }),
                onCopies: (value) => setState(() => _copies[index] = value),
              ),
            ),
          ),
          const Divider(height: 12),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _includePrice,
            onChanged: (value) => setState(() => _includePrice = value),
            secondary: const Icon(Icons.price_check_outlined),
            title: Text(l10n.barcodeLabelIncludePriceLabel),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _printing
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: Text(l10n.cancelButton),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('label-batch-print'),
                  onPressed: _printing || _total == 0 ? null : _print,
                  icon: const Icon(Icons.print_outlined),
                  label: Text(l10n.labelBatchPrintCount(_total)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.copies,
    required this.onSelected,
    required this.onCopies,
  });

  final LabelBatchEntry entry;
  final bool selected;
  final int copies;
  final ValueChanged<bool> onSelected;
  final ValueChanged<int> onCopies;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final printable = entry.printable;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Checkbox(
            value: selected,
            onChanged: printable ? (value) => onSelected(value ?? false) : null,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  printable ? entry.subtitle : l10n.labelBatchNoBarcode,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: printable ? colors.mutedInk : colors.warning,
                  ),
                ),
              ],
            ),
          ),
          // A handset group's count is fixed — one each — but sits in the same
          // column as a lot's stepper so the numbers read down one line.
          _CopiesStepper(
            value: copies,
            enabled: selected,
            fixed: !(entry.copiesEditable && printable),
            onChanged: onCopies,
            label: l10n.labelBatchCopies,
          ),
        ],
      ),
    );
  }
}

class _CopiesStepper extends StatelessWidget {
  const _CopiesStepper({
    required this.value,
    required this.enabled,
    required this.onChanged,
    required this.label,
    this.fixed = false,
  });

  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final String label;

  /// Shows the count alone, keeping the buttons' room.
  final bool fixed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    Widget button(Widget child) => Visibility(
      visible: !fixed,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: child,
    );
    return Semantics(
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: enabled && value > 1
                  ? () => onChanged(value - 1)
                  : null,
              icon: const Icon(Icons.remove, size: 18),
            ),
          ),
          SizedBox(
            width: 36,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                color: enabled ? colors.ink : colors.mutedInk,
              ),
            ),
          ),
          button(
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: enabled && value < 999
                  ? () => onChanged(value + 1)
                  : null,
              icon: const Icon(Icons.add, size: 18),
            ),
          ),
        ],
      ),
    );
  }
}
