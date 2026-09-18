import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/stock_transfer.dart';
import '../../../data/models/warehouse.dart';
import '../../../data/repositories/warehouse_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// Choosing what to send, from what the source actually has.
///
/// It searches *stock at the source*, not the catalog. A picker that offered
/// the whole catalogue would let somebody add a product the store room has none
/// of and only find out at dispatch — and the number they need in order to
/// decide how much to send is the same number that decides whether the product
/// belongs in the list at all.
Future<StockTransferDraftLine?> showTransferProductPicker(
  BuildContext context, {
  required Warehouse source,
  required Set<int> alreadyAdded,
  required WarehouseRepository repository,
}) {
  return showAdaptiveModalBottomSheet<StockTransferDraftLine>(
    context: context,
    builder: (_) => _TransferProductPicker(
      source: source,
      alreadyAdded: alreadyAdded,
      repository: repository,
    ),
  );
}

class _TransferProductPicker extends StatefulWidget {
  const _TransferProductPicker({
    required this.source,
    required this.alreadyAdded,
    required this.repository,
  });

  final Warehouse source;
  final Set<int> alreadyAdded;
  final WarehouseRepository repository;

  @override
  State<_TransferProductPicker> createState() => _TransferProductPickerState();
}

class _TransferProductPickerState extends State<_TransferProductPicker> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  List<WarehouseStockRow> _rows = const [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final result = await widget.repository.searchStockAt(
      warehouseId: widget.source.id,
      search: _search.text,
    );
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      if (result case Ok<List<WarehouseStockRow>>()) {
        _rows = result.value
            .where(
              (row) =>
                  row.quantityOnHand > 0 &&
                  !widget.alreadyAdded.contains(row.variantId),
            )
            .toList(growable: false);
      }
    });
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _load);
  }

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
          child: Text(widget.source.name, style: theme.textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _search,
            autofocus: true,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: l10n.searchProductsHint,
            ),
            onChanged: _onSearchChanged,
          ),
        ),
        const SizedBox(height: 8),
        Flexible(
          child: _isLoading
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: PointySpinner(),
                )
              : _rows.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    l10n.warehouseStockBreakdownEmpty,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _rows.length,
                  itemBuilder: (context, index) {
                    final row = _rows[index];
                    return ListTile(
                      title: Text(row.variantName),
                      subtitle: Text(
                        l10n.transferAvailableAtSource(
                          _short(row.quantityOnHand),
                        ),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                      trailing: const Icon(Icons.add),
                      onTap: () => Navigator.of(context).pop(
                        StockTransferDraftLine(
                          variantId: row.variantId,
                          variantName: row.variantName,
                          // Opens at one rather than at everything the room
                          // holds: sending the entire shelf is rarer than
                          // sending a few, and a wrong big number is worse
                          // than a wrong small one.
                          quantity: 1,
                          availableAtSource: row.quantityOnHand,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _short(double value) {
    final rounded = value.roundToDouble();
    return value == rounded
        ? rounded.toInt().toString()
        : value.toStringAsFixed(2);
  }
}
