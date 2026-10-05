import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/missing_lot.dart';
import '../../../data/models/stock_unit.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/missing_lots_view_model.dart';

/// One product's lot-less units: a scan field that ticks what it reads, and
/// the list to tick by hand, a page at a time.
class MissingLotsUnitsPane extends StatefulWidget {
  const MissingLotsUnitsPane({super.key, required this.viewModel});

  final MissingLotsViewModel viewModel;

  @override
  State<MissingLotsUnitsPane> createState() => _MissingLotsUnitsPaneState();
}

class _MissingLotsUnitsPaneState extends State<MissingLotsUnitsPane> {
  final TextEditingController _scan = TextEditingController();
  final FocusNode _scanFocus = FocusNode();
  MissingLotScanOutcome? _lastScan;

  @override
  void dispose() {
    _scan.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  Future<void> _onScan(String raw) async {
    if (raw.trim().isEmpty) {
      return;
    }
    final outcome = await widget.viewModel.scan(raw);
    if (!mounted) {
      return;
    }
    setState(() {
      _lastScan = outcome;
      if (outcome != MissingLotScanOutcome.notFound) {
        _scan.clear();
      }
    });
    _scanFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final viewModel = widget.viewModel;
    final group = viewModel.group;
    if (group == null) {
      return PointyEmptyState(
        icon: Icons.touch_app_outlined,
        title: l10n.missingLotsPickProduct,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: spacing.pagePadding.copyWith(bottom: 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PaneHeader(group: group, viewModel: viewModel),
              SizedBox(height: spacing.sm),
              ScanWedgeTarget(
                child: TextField(
                  key: const ValueKey('missing_lots_scan'),
                  controller: _scan,
                  focusNode: _scanFocus,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.qr_code_scanner_outlined),
                    hintText: l10n.missingLotsScanHint,
                  ),
                  onChanged: (_) {
                    if (_lastScan != null) {
                      setState(() => _lastScan = null);
                    }
                  },
                  onSubmitted: _onScan,
                ),
              ),
              if (_lastScan case final outcome?
                  when outcome != MissingLotScanOutcome.selected) ...[
                SizedBox(height: spacing.sm),
                PointyInlineMessage.warning(
                  message: outcome == MissingLotScanOutcome.notFound
                      ? l10n.missingLotsScanNotFound
                      : l10n.missingLotsScanAlready,
                  compact: true,
                ),
              ],
              SizedBox(height: spacing.sm),
            ],
          ),
        ),
        Expanded(
          child: PointyDataList<StockUnit>(
            items: viewModel.units,
            padding: spacing.pagePadding.copyWith(top: 0),
            isLoadingInitial: viewModel.isLoadingUnits,
            isLoadingMore: viewModel.isLoadingMore,
            hasMore: viewModel.hasMore,
            onLoadMore: viewModel.loadMore,
            hasError: viewModel.unitsFailed && viewModel.units.isEmpty,
            loadMoreFailed: viewModel.unitsFailed && viewModel.units.isNotEmpty,
            loadMoreErrorMessage: l10n.missingLotsLoadFailed,
            separatorBuilder: (_, _) => const Divider(height: 1),
            errorBuilder: (context) => PointyErrorState(
              title: l10n.missingLotsLoadFailed,
              icon: Icons.inventory_2_outlined,
              action: FilledButton.icon(
                onPressed: viewModel.retryUnits,
                icon: const Icon(Icons.sync),
                label: Text(l10n.retryButton),
              ),
            ),
            emptyBuilder: (context) => PointyEmptyState(
              icon: Icons.check_circle_outline,
              title: l10n.missingLotsEmpty,
            ),
            itemBuilder: (context, unit) => _UnitRow(
              unit: unit,
              selected: viewModel.isSelected(unit.id),
              onToggle: () => viewModel.toggle(unit.id),
            ),
          ),
        ),
      ],
    );
  }
}

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({required this.group, required this.viewModel});

  final MissingLotGroup group;
  final MissingLotsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                group.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleMedium,
              ),
              Text(
                l10n.missingLotsCount(group.count),
                style: textTheme.bodySmall?.copyWith(color: colors.warning),
              ),
            ],
          ),
        ),
        TextButton.icon(
          key: const ValueKey('missing_lots_select_all'),
          onPressed: viewModel.units.isEmpty ? null : viewModel.selectAllLoaded,
          icon: Icon(
            viewModel.allLoadedSelected
                ? Icons.deselect_outlined
                : Icons.select_all_outlined,
            size: 18,
          ),
          label: Text(
            viewModel.allLoadedSelected
                ? l10n.missingLotsClearSelection
                : l10n.missingLotsSelectAll,
          ),
        ),
      ],
    );
  }
}

class _UnitRow extends StatelessWidget {
  const _UnitRow({
    required this.unit,
    required this.selected,
    required this.onToggle,
  });

  final StockUnit unit;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    final days = unit.daysInStock;
    final details = [
      if (unit.isIdentified && unit.secondaryCode.isNotEmpty)
        unit.secondaryCode,
      if (unit.warehouseName.isNotEmpty) unit.warehouseName,
      if (days != null) l10n.posUnitPickerDaysInStock(days),
    ].join(' · ');
    return CheckboxListTile(
      key: ValueKey('missing_lot_unit_${unit.id}'),
      dense: true,
      value: selected,
      onChanged: (_) => onToggle(),
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(
        unit.isIdentified ? unit.code : l10n.stockUnitsAwaitingIdentifier,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style:
            PointyTypography.numeric(
              textTheme.bodyLarge ?? const TextStyle(),
            ).copyWith(
              fontStyle: unit.isIdentified
                  ? FontStyle.normal
                  : FontStyle.italic,
            ),
      ),
      subtitle: details.isEmpty
          ? null
          : Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}
