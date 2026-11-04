import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/reorder_queue.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/pointy_order_toggle_row.dart';
import '../../../shared/units.dart';

/// The queue's column widths, shared by the header and every row so they line
/// up however long a product's name runs.
abstract final class ReorderColumns {
  static const double status = 96;
  static const double figure = 76;
  static const double quantity = 92;
  static const double check = 40;

  /// Below this the figures fold under the name.
  static const double tableMinWidth = 720;
}

class ReorderHeaderRow extends StatelessWidget {
  const ReorderHeaderRow({
    super.key,
    required this.allSelected,
    required this.onToggleAll,
  });

  final bool allSelected;
  final VoidCallback onToggleAll;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: context.pointyColors.mutedInk,
      fontWeight: FontWeight.w700,
    );
    Widget figure(String label) => SizedBox(
      width: ReorderColumns.figure,
      child: Text(label, style: style, textAlign: TextAlign.center),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: ReorderColumns.check,
            child: InkWell(
              key: const ValueKey('reorder_select_all'),
              onTap: onToggleAll,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: PointyCheckBox(value: allSelected),
              ),
            ),
          ),
          Expanded(child: Text(l10n.reorderColumnProduct, style: style)),
          SizedBox(
            width: ReorderColumns.status,
            child: Text(l10n.reorderColumnStatus, style: style),
          ),
          figure(l10n.reorderColumnOnHand),
          figure(l10n.reorderColumnThreshold),
          figure(l10n.reorderColumnExpected),
          SizedBox(
            width: ReorderColumns.quantity,
            child: Text(
              l10n.reorderColumnQuantity,
              style: style,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class ReorderRowTile extends StatelessWidget {
  const ReorderRowTile({
    super.key,
    required this.row,
    required this.selected,
    required this.quantity,
    required this.tableLayout,
    required this.onToggle,
    required this.onQuantityChanged,
  });

  final ReorderRow row;
  final bool selected;
  final double quantity;
  final bool tableLayout;
  final VoidCallback onToggle;
  final ValueChanged<double> onQuantityChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final quantityField = SizedBox(
      width: ReorderColumns.quantity,
      child: _QuantityField(
        key: ValueKey('reorder_quantity_${row.variantId}'),
        quantity: quantity,
        onChanged: onQuantityChanged,
      ),
    );
    return Material(
      color: selected ? colors.primaryContainer : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        side: BorderSide(color: selected ? colors.primaryStrong : colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('reorder_row_${row.variantId}'),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: tableLayout
              ? Row(
                  children: [
                    SizedBox(
                      width: ReorderColumns.check,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: PointyCheckBox(value: selected),
                      ),
                    ),
                    Expanded(child: _RowIdentity(row: row)),
                    SizedBox(
                      width: ReorderColumns.status,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: _StatusPill(status: row.status),
                      ),
                    ),
                    _Figure(value: row.onHand),
                    _Figure(value: row.threshold),
                    _Figure(value: row.expected),
                    quantityField,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: ReorderColumns.check,
                          child: Align(
                            alignment: AlignmentDirectional.topStart,
                            child: PointyCheckBox(value: selected),
                          ),
                        ),
                        Expanded(child: _RowIdentity(row: row)),
                        const SizedBox(width: 8),
                        _StatusPill(status: row.status),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _CompactFigures(row: row)),
                        quantityField,
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _RowIdentity extends StatelessWidget {
  const _RowIdentity({required this.row});

  final ReorderRow row;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final notes = [
      if (row.sku.isNotEmpty) ltrIsolated(row.sku),
      if (row.daysLeft case final days?) l10n.reorderDaysLeft(days),
      if (row.lastSupplierName.isNotEmpty)
        l10n.reorderLastSupplier(row.lastSupplierName),
      if (row.inDraft > 0)
        l10n.reorderInDraft(ltrIsolated(formatQuantity(row.inDraft))),
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          row.variantName.isEmpty
              ? row.productName
              : '${row.productName} — ${row.variantName}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            notes,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final ReorderStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return PointyStatusPill(
      label: switch (status) {
        ReorderStatus.out => l10n.stockStatusOut,
        ReorderStatus.low => l10n.stockStatusLow,
        ReorderStatus.approaching => l10n.reorderStatusApproaching,
      },
      color: switch (status) {
        ReorderStatus.out => colors.danger,
        ReorderStatus.low => colors.warning,
        ReorderStatus.approaching => colors.mutedInk,
      },
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: ReorderColumns.figure,
      child: Text(
        ltrIsolated(formatQuantity(value)),
        textAlign: TextAlign.center,
        style: PointyTypography.numeric(
          Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
        ),
      ),
    );
  }
}

class _CompactFigures extends StatelessWidget {
  const _CompactFigures({required this.row});

  final ReorderRow row;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final figures = [
      '${l10n.reorderColumnOnHand} ${ltrIsolated(formatQuantity(row.onHand))}',
      '${l10n.reorderColumnThreshold} ${ltrIsolated(formatQuantity(row.threshold))}',
      if (row.expected > 0)
        '${l10n.reorderColumnExpected} ${ltrIsolated(formatQuantity(row.expected))}',
    ].join(' · ');
    return Text(
      figures,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: context.pointyColors.ink),
    );
  }
}

/// The quantity to order, typed straight into the row. Every keystroke counts,
/// so pressing the order button with the cursor still here loses nothing; on
/// leaving, anything that is not above zero goes back to what it was.
class _QuantityField extends StatefulWidget {
  const _QuantityField({
    super.key,
    required this.quantity,
    required this.onChanged,
  });

  final double quantity;
  final ValueChanged<double> onChanged;

  @override
  State<_QuantityField> createState() => _QuantityFieldState();
}

class _QuantityFieldState extends State<_QuantityField> {
  late final _controller = TextEditingController(text: _text(widget.quantity));
  final _focusNode = FocusNode();

  static String _text(double quantity) => formatQuantity(quantity);

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _QuantityField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.quantity != widget.quantity && !_focusNode.hasFocus) {
      _controller.text = _text(widget.quantity);
    }
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) {
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    } else {
      _commit();
    }
  }

  void _report(String text) {
    final typed = double.tryParse(text.trim());
    if (typed != null && typed > 0) {
      widget.onChanged(typed);
    }
  }

  void _commit() {
    _controller.text = _text(widget.quantity);
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        ),
        onChanged: _report,
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}
