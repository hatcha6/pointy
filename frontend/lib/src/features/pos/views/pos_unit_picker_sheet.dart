import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/stock_unit.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/components/pointy_progress.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';

/// Which handset is the cashier selling?
///
/// Opened when a serialized product is tapped rather than scanned. The list is
/// **oldest first**, which is the whole point of showing days-in-stock next to
/// each row: stock ages, an unsold handset loses value every week, and the one
/// a used-goods trader wants gone is the one that has been sitting longest.
///
/// A scanner pointed at this sheet types into the search field, so it declares
/// itself a [ScanWedgeTarget]: without that, `ScanBurstGuard` rolls the digits
/// back as a stray burst and the capture appears to simply not work.
Future<StockUnit?> showPosUnitPickerSheet(
  BuildContext context, {
  required TrackedStockRepository repository,
  required int variantId,
  required String productLabel,
}) {
  return showModalBottomSheet<StockUnit>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) {
      return _PosUnitPickerSheet(
        repository: repository,
        variantId: variantId,
        productLabel: productLabel,
      );
    },
  );
}

class _PosUnitPickerSheet extends StatefulWidget {
  const _PosUnitPickerSheet({
    required this.repository,
    required this.variantId,
    required this.productLabel,
  });

  final TrackedStockRepository repository;
  final int variantId;
  final String productLabel;

  @override
  State<_PosUnitPickerSheet> createState() => _PosUnitPickerSheetState();
}

class _PosUnitPickerSheetState extends State<_PosUnitPickerSheet> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  List<StockUnit> _units = const [];
  bool _isLoading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final result = await widget.repository.loadSellableUnits(
      variantId: widget.variantId,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = false;
      switch (result) {
        case Ok<StockUnitPage>(:final value):
          _units = value.units;
          _error = '';
        case Error<StockUnitPage>():
          _units = const [];
          _error = AppLocalizations.of(context)!.posUnitPickerLoadFailed;
      }
    });
    // Focus after the list lands so a scanner burst cannot arrive before there
    // is anything to filter.
    if (mounted) {
      _searchFocus.requestFocus();
    }
  }

  /// Matches either identifier, because a dual-SIM handset is scanned off
  /// whichever of its two numbers the box happens to show.
  List<StockUnit> get _visible {
    final term = _search.text.trim().toUpperCase().replaceAll(
      RegExp(r'[\s\-._/]'),
      '',
    );
    if (term.isEmpty) {
      return _units;
    }
    return _units
        .where(
          (unit) =>
              _normalize(unit.code).contains(term) ||
              _normalize(unit.secondaryCode).contains(term),
        )
        .toList(growable: false);
  }

  String _normalize(String value) =>
      value.toUpperCase().replaceAll(RegExp(r'[\s\-._/]'), '');

  void _submit() {
    final matches = _visible;
    if (matches.length == 1) {
      Navigator.of(context).pop(matches.first);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final visible = _visible;

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
                const Icon(Icons.qr_code_2_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.posUnitPickerTitle(widget.productLabel),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ScanWedgeTarget(
              child: TextField(
                controller: _search,
                focusNode: _searchFocus,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: l10n.posUnitPickerSearchHint,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(height: 8),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: PointySpinner()),
              )
            else if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(_error, textAlign: TextAlign.center),
              )
            else if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  l10n.posUnitPickerEmpty,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    return _UnitRow(
                      unit: visible[index],
                      onTap: () => Navigator.of(context).pop(visible[index]),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _UnitRow extends StatelessWidget {
  const _UnitRow({required this.unit, required this.onTap});

  final StockUnit unit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final days = unit.daysInStock;
    final price = unit.listPrice;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      title: Text(
        unit.code,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge,
      ),
      subtitle: Wrap(
        spacing: 10,
        runSpacing: 2,
        children: [
          if (days != null)
            Text(
              l10n.posUnitPickerDaysInStock(days),
              style: theme.textTheme.bodySmall?.copyWith(
                // Old stock is the point of the list, so it is the one thing
                // here that changes colour.
                color: days >= 90 ? colors.warning : theme.hintColor,
              ),
            ),
          if (unit.batchCode.isNotEmpty)
            Text(
              l10n.posCartLineBatchBadge(unit.batchCode),
              style: theme.textTheme.bodySmall,
            ),
          if (unit.batchExpiryDate != null)
            Text(
              l10n.posCartLineExpiryBadge(formatExpiry(unit.batchExpiryDate!)),
              style: theme.textTheme.bodySmall,
            ),
          if (unit.isConsignment)
            Text(
              l10n.posUnitPickerConsignment,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.primaryStrong,
              ),
            ),
        ],
      ),
      trailing: price == null
          ? null
          : Text(formatMoney(price), style: theme.textTheme.titleSmall),
    );
  }
}
