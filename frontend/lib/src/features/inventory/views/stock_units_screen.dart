import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/stock_unit.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/tracked_stock_view_model.dart';
import 'opening_identification_screen.dart';
import 'stock_unit_detail_screen.dart';

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
    this.repository,
  });

  final TrackedStockViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  /// For the opening-identification run behind the app bar. Optional so a
  /// shop with nothing anonymous on the shelf pays nothing for it.
  final TrackedStockRepository? repository;

  @override
  State<StockUnitsScreen> createState() => _StockUnitsScreenState();
}

class _StockUnitsScreenState extends State<StockUnitsScreen> {
  final TextEditingController _search = TextEditingController();

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
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.stockUnitsTitle),
            isLoading: viewModel.isLoadingUnits,
            actions: [
              if (widget.repository != null &&
                  widget.capabilities.canViewStockUnits)
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
        );
      },
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
                          label: Text(_statusLabel(l10n, status)),
                          selected: viewModel.unitStatus == status,
                          onSelected: (_) => viewModel.setUnitStatus(status),
                        ),
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
      itemBuilder: (context, unit) =>
          _UnitRow(unit: unit, onTap: () => _openDetail(context, unit)),
    );
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
        ),
      ),
    );
    if (context.mounted) {
      unawaited(widget.viewModel.loadUnits());
    }
  }

  String _statusLabel(AppLocalizations l10n, String status) {
    return switch (status) {
      StockUnitStatus.inStock => l10n.stockUnitStatusInStock,
      StockUnitStatus.reserved => l10n.stockUnitStatusReserved,
      StockUnitStatus.sold => l10n.stockUnitStatusSold,
      StockUnitStatus.damaged => l10n.stockUnitStatusDamaged,
      StockUnitStatus.writtenOff => l10n.stockUnitStatusWrittenOff,
      _ => status,
    };
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

    return ListTile(
      onTap: onTap,
      leading: Icon(
        unit.isIdentified ? Icons.qr_code_2_outlined : Icons.help_outline,
        color: unit.isIdentified ? null : colors.warning,
      ),
      title: Text(
        unit.isIdentified ? unit.code : l10n.stockUnitsAwaitingIdentifier,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontStyle: unit.isIdentified ? FontStyle.normal : FontStyle.italic,
        ),
      ),
      subtitle: Text(
        [
          if (unit.productName.isNotEmpty) unit.productName,
          if (unit.batchCode.isNotEmpty)
            l10n.posCartLineBatchBadge(unit.batchCode),
          if (unit.isOnHand && days != null)
            l10n.posUnitPickerDaysInStock(days),
          if (unit.soldAt != null) formatDate(unit.soldAt!),
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: unit.showsCost
          ? Text(
              formatMoney(unit.totalCost!),
              style: theme.textTheme.titleSmall,
            )
          : (unit.listPrice == null
                ? null
                : Text(
                    formatMoney(unit.listPrice!),
                    style: theme.textTheme.titleSmall,
                  )),
    );
  }
}
