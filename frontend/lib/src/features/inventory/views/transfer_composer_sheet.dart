import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/stock_transfer.dart';
import '../../../data/models/warehouse.dart';
import '../../../data/repositories/warehouse_repository.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import 'transfer_product_picker.dart';

/// What the composer hands back: the transfer, and whether to send it now.
class TransferComposerOutcome {
  const TransferComposerOutcome({required this.draft, required this.sendNow});

  final StockTransferDraft draft;
  final bool sendNow;
}

Future<TransferComposerOutcome?> showTransferComposer(
  BuildContext context, {
  required List<Warehouse> places,
  required WarehouseRepository repository,
}) {
  return showAdaptiveModalBottomSheet<TransferComposerOutcome>(
    context: context,
    builder: (_) =>
        _TransferComposerSheet(places: places, repository: repository),
  );
}

/// Writing a transfer.
///
/// The direction comes first and stays visible, because everything below it
/// means something different depending on which way the goods are going — and
/// because "from the store room to the shop floor" is the sentence the person
/// is holding in their head while they walk around adding things.
class _TransferComposerSheet extends StatefulWidget {
  const _TransferComposerSheet({
    required this.places,
    required this.repository,
  });

  final List<Warehouse> places;
  final WarehouseRepository repository;

  @override
  State<_TransferComposerSheet> createState() => _TransferComposerSheetState();
}

class _TransferComposerSheetState extends State<_TransferComposerSheet> {
  late Warehouse _source = widget.places.first;
  late Warehouse _destination = widget.places.length > 1
      ? widget.places[1]
      : widget.places.first;
  final List<StockTransferDraftLine> _lines = [];
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool get _isSendable =>
      _lines.isNotEmpty &&
      _source.id != _destination.id &&
      _lines.every((line) => line.quantity > 0);

  StockTransferDraft get _draft => StockTransferDraft(
    source: _source,
    destination: _destination,
    lines: List.unmodifiable(_lines),
    note: _note.text,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            l10n.transferComposerTitle,
            style: theme.textTheme.titleMedium,
          ),
        ),
        // Direction, pinned above everything it changes the meaning of.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: _PlacePicker(
                  label: l10n.transferFromLabel,
                  value: _source,
                  places: widget.places,
                  onChanged: (place) => setState(() {
                    _source = place;
                    if (_destination.id == place.id) {
                      _destination = widget.places.firstWhere(
                        (other) => other.id != place.id,
                        orElse: () => place,
                      );
                    }
                    // Availability was read against the old source, so the
                    // numbers beside each line no longer mean anything.
                    _lines.clear();
                  }),
                ),
              ),
              IconButton(
                tooltip: l10n.transferSwapTooltip,
                onPressed: () => setState(() {
                  final was = _source;
                  _source = _destination;
                  _destination = was;
                  _lines.clear();
                }),
                icon: const Icon(Icons.swap_horiz),
              ),
              Expanded(
                child: _PlacePicker(
                  label: l10n.transferToLabel,
                  value: _destination,
                  places: widget.places
                      .where((place) => place.id != _source.id)
                      .toList(),
                  onChanged: (place) => setState(() => _destination = place),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 24),
        Flexible(
          child: _lines.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 32,
                  ),
                  child: Text(
                    l10n.transferNoLinesYet,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _lines.length,
                  itemBuilder: (context, index) => _LineTile(
                    line: _lines[index],
                    sourceName: _source.name,
                    onChanged: (quantity) => setState(
                      () => _lines[index] = _lines[index].copyWith(
                        quantity: quantity,
                      ),
                    ),
                    onRemove: () => setState(() => _lines.removeAt(index)),
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            onPressed: _addLine,
            icon: const Icon(Icons.add),
            label: Text(l10n.transferAddProduct),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TextField(
            controller: _note,
            decoration: InputDecoration(labelText: l10n.transferNoteLabel),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _isSendable
                      ? () => Navigator.of(context).pop(
                          TransferComposerOutcome(
                            draft: _draft,
                            sendNow: false,
                          ),
                        )
                      : null,
                  child: Text(l10n.transferSaveDraftAction),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                // The common case gets the filled button: somebody standing at
                // the store room with a box in their hands is sending it now,
                // not saving it for later.
                child: FilledButton(
                  onPressed: _isSendable
                      ? () => Navigator.of(context).pop(
                          TransferComposerOutcome(draft: _draft, sendNow: true),
                        )
                      : null,
                  child: Text(l10n.transferSendNowAction),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _addLine() async {
    final added = await showTransferProductPicker(
      context,
      source: _source,
      alreadyAdded: _lines.map((line) => line.variantId).toSet(),
      repository: widget.repository,
    );
    if (added == null) return;
    setState(() => _lines.add(added));
  }
}

class _PlacePicker extends StatelessWidget {
  const _PlacePicker({
    required this.label,
    required this.value,
    required this.places,
    required this.onChanged,
  });

  final String label;
  final Warehouse value;
  final List<Warehouse> places;
  final ValueChanged<Warehouse> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int>(
      initialValue: value.id,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final place in places)
          DropdownMenuItem(
            value: place.id,
            child: Text(place.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (id) {
        if (id == null) return;
        onChanged(places.firstWhere((place) => place.id == id));
      },
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.line,
    required this.sourceName,
    required this.onChanged,
    required this.onRemove,
  });

  final StockTransferDraftLine line;
  final String sourceName;
  final ValueChanged<double> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final tooMuch = line.exceedsSource;

    return ListTile(
      title: Text(line.variantName),
      subtitle: Text(
        // What the source actually has, beside the field. Typing more than the
        // shop floor holds should be visible here, not discovered at dispatch
        // when the server refuses it.
        tooMuch
            ? l10n.transferExceedsSource(sourceName)
            : l10n.transferAvailableAtSource(_short(line.availableAtSource)),
        style: theme.textTheme.labelSmall?.copyWith(
          color: tooMuch ? colors.danger : colors.mutedInk,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 74,
            child: TextFormField(
              initialValue: _short(line.quantity),
              textAlign: TextAlign.center,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(isDense: true),
              onChanged: (text) => onChanged(double.tryParse(text) ?? 0),
            ),
          ),
          IconButton(onPressed: onRemove, icon: const Icon(Icons.close)),
        ],
      ),
    );
  }

  String _short(double value) {
    final rounded = value.roundToDouble();
    return value == rounded
        ? rounded.toInt().toString()
        : value.toStringAsFixed(2);
  }
}
