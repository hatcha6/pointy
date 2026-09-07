import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/stock_transfer.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// Taking goods off the road.
///
/// Opens with everything already marked arrived, because that is what happens
/// almost every time: the van turns up with what was put in it. Confirming is
/// one tap, and the person who needs to say "two of the six are missing" edits
/// two fields instead of filling in six.
Future<Map<int, double>?> showTransferReceiveSheet(
  BuildContext context, {
  required StockTransfer transfer,
}) {
  return showAdaptiveModalBottomSheet<Map<int, double>>(
    context: context,
    builder: (_) => _TransferReceiveSheet(transfer: transfer),
  );
}

class _TransferReceiveSheet extends StatefulWidget {
  const _TransferReceiveSheet({required this.transfer});

  final StockTransfer transfer;

  @override
  State<_TransferReceiveSheet> createState() => _TransferReceiveSheetState();
}

class _TransferReceiveSheetState extends State<_TransferReceiveSheet> {
  late final Map<int, double> _arrived = {
    for (final line in _outstanding) line.id: line.outstandingQuantity,
  };

  List<StockTransferLine> get _outstanding => widget.transfer.lines
      .where((line) => line.outstandingQuantity > 0)
      .toList(growable: false);

  bool get _canConfirm => _arrived.values.any((quantity) => quantity > 0);

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
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            l10n.transferReceiveTitle(widget.transfer.transferNumber),
            style: theme.textTheme.titleMedium,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            l10n.transferJourneyLabel(
              widget.transfer.sourceName,
              widget.transfer.destinationName,
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            l10n.transferReceiveSomeHint,
            style: theme.textTheme.labelSmall?.copyWith(color: colors.mutedInk),
          ),
        ),
        const Divider(height: 20),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final line in _outstanding)
                _ReceiveLineTile(
                  line: line,
                  value: _arrived[line.id] ?? 0,
                  onChanged: (quantity) => setState(
                    () => _arrived[line.id] = quantity.clamp(
                      0,
                      line.outstandingQuantity,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  // The escape hatch from any editing: put it all back to "all
                  // of it arrived", which is where the sheet started.
                  onPressed: () => setState(() {
                    for (final line in _outstanding) {
                      _arrived[line.id] = line.outstandingQuantity;
                    }
                  }),
                  child: Text(l10n.transferReceiveAllAction),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _canConfirm
                      ? () => Navigator.of(context).pop(
                          Map<int, double>.fromEntries(
                            _arrived.entries.where((entry) => entry.value > 0),
                          ),
                        )
                      : null,
                  child: Text(l10n.transferReceiveConfirm),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ReceiveLineTile extends StatelessWidget {
  const _ReceiveLineTile({
    required this.line,
    required this.value,
    required this.onChanged,
  });

  final StockTransferLine line;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final isShort = value < line.outstandingQuantity;

    return ListTile(
      title: Text(line.variantName),
      subtitle: Text(
        line.variantSku,
        style: theme.textTheme.labelSmall?.copyWith(color: colors.mutedInk),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Stepper buttons rather than only a keyboard: receiving happens
          // standing up, often one-handed, and "one short" is the commonest
          // correction there is.
          IconButton(
            onPressed: value <= 0 ? null : () => onChanged(value - 1),
            icon: const Icon(Icons.remove_circle_outline),
          ),
          SizedBox(
            width: 52,
            child: Text(
              _short(value),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                color: isShort ? colors.warning : colors.ink,
              ),
            ),
          ),
          IconButton(
            onPressed: value >= line.outstandingQuantity
                ? null
                : () => onChanged(value + 1),
            icon: const Icon(Icons.add_circle_outline),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '/ ${_short(line.outstandingQuantity)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
          ),
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
