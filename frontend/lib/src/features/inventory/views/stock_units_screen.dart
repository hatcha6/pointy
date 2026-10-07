import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/barcode_label.dart';
import '../../../data/models/stock_unit.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/tracking/tracking_labels.dart';
import '../../catalog/views/label_batch_print_sheet.dart';
import '../view_models/tracked_stock_view_model.dart';
import 'identify_unit_dialog.dart';
import 'missing_lots_screen.dart';
import 'opening_identification_screen.dart';
import 'stock_unit_detail_screen.dart';
import 'stock_unit_row.dart';
import 'variant_filter_chips.dart';

/// Every article this shop has identified, and what became of it.
///
/// The search field is a `ScanWedgeTarget`: a scanner pointed at this screen is
/// asking *"where is this one?"*, and a burst guard that rolled its digits back
/// would make the answer arrive as a search for nothing.
class StockUnitsScreen extends StatefulWidget {
  const StockUnitsScreen({
    super.key,
    required this.viewModel,
    required this.capabilities,
    this.navigation,
    this.repository,
    this.printingRepository,
    this.onOpenRecord,
  });

  final TrackedStockViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  /// The app's drawer, when this is a destination. Null when it was opened
  /// from somewhere — one product's page — and goes back there instead.
  final AppNavigation? navigation;

  /// For the opening-identification run behind the app bar. Optional so a
  /// shop with nothing anonymous on the shelf pays nothing for it.
  final TrackedStockRepository? repository;

  /// Labels for chosen articles — each one's own number and price. Null hides
  /// the action.
  final PrintingRepository? printingRepository;

  /// Handed to each article's page, for its invoice and buyer links.
  final Future<bool> Function(BuildContext context, String type, int id)?
  onOpenRecord;

  @override
  State<StockUnitsScreen> createState() => _StockUnitsScreenState();
}

class _StockUnitsScreenState extends State<StockUnitsScreen> {
  final TextEditingController _search = TextEditingController();

  /// Choosing articles to print labels for. Null when not choosing.
  Set<int>? _selected;

  bool get _selecting => _selected != null;

  void _toggle(StockUnit unit) {
    setState(() {
      final selected = _selected!;
      selected.contains(unit.id)
          ? selected.remove(unit.id)
          : selected.add(unit.id);
    });
  }

  Future<void> _printSelected() async {
    final printing = widget.printingRepository;
    final selected = _selected;
    if (printing == null || selected == null || selected.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final units = [
      for (final unit in widget.viewModel.units)
        if (selected.contains(unit.id) && unit.isIdentified) unit,
    ];
    // One row per variant: the sheet stays short, and each row still prints
    // one sticker per handset, each with its own number and price.
    final byVariant = <int, List<StockUnit>>{};
    for (final unit in units) {
      byVariant.putIfAbsent(unit.variantId, () => []).add(unit);
    }
    await showLabelBatchPrintSheet(
      context,
      title: l10n.labelBatchUnitsTitle,
      printingRepository: printing,
      entries: [
        for (final group in byVariant.values)
          LabelBatchEntry(
            title: group.first.variantName.isNotEmpty
                ? group.first.variantName
                : group.first.productName,
            subtitle: l10n.labelBatchUnitsEntry(group.length),
            lines: [for (final unit in group) BarcodeLabelPrintLine.unit(unit)],
          ),
      ],
    );
    if (mounted) setState(() => _selected = null);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(widget.viewModel.loadUnits());
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = widget.viewModel;
        final navigation = widget.navigation;
        return PointyScaffold(
          drawer: navigation == null
              ? null
              : AppNavigationDrawer(
                  selectedDestination: AppNavigationDestination.stockUnits,
                  navigation: navigation,
                ),
          appBar: PointyAppBar(
            leading: navigation == null
                ? null
                : const PointyNavigationMenuButton(),
            title: Text(l10n.stockUnitsTitle),
            isLoading: viewModel.isLoadingUnits,
            actions: [
              if (widget.printingRepository != null && !_selecting)
                IconButton(
                  key: const ValueKey('stock_units_select_for_labels'),
                  tooltip: l10n.stockUnitsSelectForLabels,
                  onPressed: () => setState(() => _selected = <int>{}),
                  icon: const Icon(Icons.print_outlined),
                ),
              if (widget.repository != null &&
                  widget.capabilities.canIdentifyStockUnits)
                IconButton(
                  tooltip: l10n.openingIdentifyTitle,
                  onPressed: _openOpeningIdentification,
                  icon: const Icon(Icons.playlist_add_check_outlined),
                ),
              IconButton(
                tooltip: l10n.refreshShopSettingsTooltip,
                onPressed: viewModel.isLoadingUnits
                    ? null
                    : viewModel.loadUnits,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: _body(context, l10n, viewModel),
          bottomNavigationBar: _selecting ? _selectionBar(l10n) : null,
        );
      },
    );
  }

  Widget _selectionBar(AppLocalizations l10n) {
    final selected = _selected!;
    final identified = [
      for (final unit in widget.viewModel.units)
        if (unit.isIdentified) unit.id,
    ];
    return SafeArea(
      child: Material(
        elevation: 6,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Text(l10n.stockUnitsSelectedCount(selected.length)),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => selected.addAll(identified)),
                child: Text(l10n.stockUnitsSelectAll),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _selected = null),
                child: Text(l10n.stockUnitsCancelSelection),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const ValueKey('stock_units_print_selected'),
                onPressed: selected.isEmpty ? null : _printSelected,
                icon: const Icon(Icons.print_outlined),
                label: Text(l10n.stockUnitsPrintSelected),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openOpeningIdentification() async {
    final repository = widget.repository;
    if (repository == null) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            OpeningIdentificationScreen(repository: repository),
      ),
    );
    if (!mounted) {
      return;
    }
    await widget.viewModel.loadUnits();
  }

  Future<void> _openMissingLots() async {
    final repository = widget.repository;
    if (repository == null) {
      return;
    }
    await openMissingLotsScreen(
      context,
      repository: repository,
      // Shop-wide, like the count on the callout that opened it.
      canAssign: widget.capabilities.canIdentifyStockUnits,
    );
    if (!mounted) {
      return;
    }
    await widget.viewModel.loadUnits();
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    TrackedStockViewModel viewModel,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: spacing.pagePadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScanWedgeTarget(
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: l10n.stockUnitsSearchHint,
                  ),
                  onSubmitted: viewModel.setUnitSearch,
                ),
              ),
              const SizedBox(height: 10),
              if (viewModel.productId != null) ...[
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: InputChip(
                    key: const ValueKey('stock_units_product_filter'),
                    avatar: const Icon(Icons.inventory_2_outlined, size: 18),
                    label: Text(viewModel.productName),
                    onDeleted: viewModel.clearProductFilter,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (viewModel.variantChoices.isNotEmpty) ...[
                VariantFilterChips(
                  viewModel: viewModel,
                  onSelected: (id) =>
                      viewModel.setVariantFilter(id, units: true),
                ),
                const SizedBox(height: 10),
              ],
              if (viewModel.batchId != null) ...[
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: InputChip(
                    key: const ValueKey('stock_units_batch_filter'),
                    avatar: const Icon(Icons.inventory_2_outlined, size: 18),
                    label: Text(
                      l10n.stockUnitsBatchFilter(viewModel.batchLabel),
                    ),
                    onDeleted: viewModel.clearBatchFilter,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final status in const [
                      StockUnitStatus.inStock,
                      StockUnitStatus.reserved,
                      StockUnitStatus.sold,
                      StockUnitStatus.damaged,
                      StockUnitStatus.writtenOff,
                    ])
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 6),
                        child: ChoiceChip(
                          label: Text(stockUnitStatusLabel(l10n, status)),
                          selected:
                              !viewModel.missingOnly &&
                              viewModel.unitStatus == status,
                          onSelected: (_) => viewModel.setUnitStatus(status),
                        ),
                      ),
                    // The worklist, beside the statuses rather than instead of
                    // them: articles still owed a number, to name one by one.
                    if (viewModel.missingIdentifiers > 0 ||
                        viewModel.missingOnly)
                      ChoiceChip(
                        key: const ValueKey('stock_units_missing_filter'),
                        avatar: const Icon(
                          Icons.pending_actions_outlined,
                          size: 18,
                        ),
                        label: Text(l10n.stockUnitsAwaitingIdentifier),
                        selected: viewModel.missingOnly,
                        onSelected: viewModel.setMissingOnly,
                      ),
                  ],
                ),
              ),
              if (viewModel.missingIdentifiers > 0) ...[
                const SizedBox(height: 10),
                // Not a badge tucked in a corner: a delivery whose identifiers
                // were never captured is stock the till cannot sell, and the
                // number is the whole point.
                PointyDetailCallout(
                  icon: Icons.pending_actions_outlined,
                  tone: PointyCalloutTone.warning,
                  title: l10n.stockUnitsMissingIdentifiers(
                    viewModel.missingIdentifiers,
                  ),
                  trailing: viewModel.missingOnly
                      ? null
                      : TextButton(
                          onPressed: () => viewModel.setMissingOnly(true),
                          child: Text(l10n.stockUnitsShowMissing),
                        ),
                ),
              ],
              // Units a `serial → serial_batch` switch left without a lot
              // (§4.2): they sell, but no recall can find them.
              if (viewModel.summary.missingLots > 0 &&
                  widget.repository != null) ...[
                const SizedBox(height: 10),
                PointyDetailCallout(
                  key: const ValueKey('stock_units_missing_lots'),
                  icon: Icons.inventory_2_outlined,
                  tone: PointyCalloutTone.warning,
                  title: l10n.missingLotsCount(viewModel.summary.missingLots),
                  trailing: TextButton(
                    onPressed: _openMissingLots,
                    child: Text(l10n.stockUnitsAssignLotsAction),
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(child: _list(context, l10n, viewModel)),
      ],
    );
  }

  Widget _list(
    BuildContext context,
    AppLocalizations l10n,
    TrackedStockViewModel viewModel,
  ) {
    // PointyDataList owns the loading/error/empty ladder, the content skeleton
    // and the load-more trigger. Hand-rolling it here is what left the screen
    // showing page one only: a shop with three thousand handsets could reach
    // fifty of them, and nothing said there were more.
    final spacing = AdaptiveSpacing.of(context);
    return PointyDataList<StockUnit>(
      items: viewModel.units,
      padding: spacing.pagePadding,
      isLoadingInitial: viewModel.isLoadingUnits,
      isLoadingMore: viewModel.isLoadingMoreUnits,
      hasMore: viewModel.hasMoreUnits,
      onLoadMore: viewModel.loadMoreUnits,
      hasError: viewModel.hasUnitError,
      separatorBuilder: (_, _) => const Divider(height: 1),
      errorBuilder: (context) => PointyErrorState(
        title: l10n.stockUnitsTitle,
        icon: Icons.qr_code_2_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.loadUnits,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      ),
      emptyBuilder: (context) => PointyEmptyState(
        icon: Icons.qr_code_2_outlined,
        title: l10n.stockUnitsEmptyTitle,
        message: l10n.stockUnitsEmptyBody,
      ),
      itemBuilder: (context, unit) => StockUnitRow(
        unit: unit,
        selecting: _selecting,
        selected: _selected?.contains(unit.id) ?? false,
        onTap: () => _selecting
            ? (unit.isIdentified ? _toggle(unit) : null)
            : _openDetail(context, unit),
        onIdentify:
            !unit.isIdentified &&
                unit.isOnHand &&
                widget.capabilities.canIdentifyStockUnits
            ? () => _identify(context, unit)
            : null,
      ),
    );
  }

  Future<void> _identify(BuildContext context, StockUnit unit) async {
    final named = await showIdentifyUnitDialog(
      context,
      viewModel: widget.viewModel,
      unit: unit,
    );
    if (named && context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.stockUnitIdentified),
          ),
        );
    }
  }

  Future<void> _openDetail(BuildContext context, StockUnit unit) async {
    // A row opens the article, not a sheet of its movements: the page a
    // warranty claim or a police question is answered from has the timeline on
    // it, and everything else besides.
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => StockUnitDetailScreen(
          viewModel: widget.viewModel,
          unit: unit,
          capabilities: widget.capabilities,
          onOpenRecord: widget.onOpenRecord,
          printingRepository: widget.printingRepository,
        ),
      ),
    );
    if (context.mounted) {
      unawaited(widget.viewModel.loadUnits());
    }
  }
}
