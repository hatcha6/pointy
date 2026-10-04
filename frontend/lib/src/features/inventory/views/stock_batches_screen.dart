import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/stock_batch.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/units.dart';
import '../view_models/tracked_stock_view_model.dart';
import 'batch_recall_screen.dart';
import 'opening_identification_screen.dart';

/// The lots this shop has held, and where their goods are now.
///
/// Every row is **one lot**, whatever it has been through and however many
/// places it currently sits in. That is the shape the identity/balance split
/// exists to make possible: a recall is one row to act on, and "where is Lot A?"
/// is a panel underneath it rather than a search for rows that share a name.
class StockBatchesScreen extends StatefulWidget {
  const StockBatchesScreen({
    super.key,
    required this.viewModel,
    this.navigation,
    this.repository,
    this.canQuarantine = false,
    this.canIdentify = false,
  });

  final TrackedStockViewModel viewModel;

  /// The app's drawer, when this is a destination; null when opened from one
  /// product's page, which it goes back to instead.
  final AppNavigation? navigation;

  /// Whether the opening-identification run is offered here too — for a shop
  /// that tracks lots and not serials, this screen is the only way to it.
  final bool canIdentify;

  /// For the recall screen behind a row. Optional so a shop that never
  /// recalls anything pays nothing for it.
  final TrackedStockRepository? repository;
  final bool canQuarantine;

  @override
  State<StockBatchesScreen> createState() => _StockBatchesScreenState();
}

class _StockBatchesScreenState extends State<StockBatchesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(widget.viewModel.loadBatches());
    });
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
                  selectedDestination: AppNavigationDestination.stockBatches,
                  navigation: navigation,
                ),
          appBar: PointyAppBar(
            leading: navigation == null
                ? null
                : const PointyNavigationMenuButton(),
            title: Text(l10n.stockBatchesTitle),
            isLoading: viewModel.isLoadingBatches,
            actions: [
              if (widget.repository != null && widget.canIdentify)
                IconButton(
                  tooltip: l10n.openingIdentifyTitle,
                  onPressed: _openOpeningIdentification,
                  icon: const Icon(Icons.playlist_add_check_outlined),
                ),
              IconButton(
                tooltip: l10n.refreshShopSettingsTooltip,
                onPressed: viewModel.isLoadingBatches
                    ? null
                    : viewModel.loadBatches,
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
    await widget.viewModel.loadBatches();
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
        if (viewModel.productId != null)
          Padding(
            padding: spacing.pagePadding.copyWith(bottom: 0),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: InputChip(
                key: const ValueKey('stock_batches_product_filter'),
                avatar: const Icon(Icons.inventory_2_outlined, size: 18),
                label: Text(viewModel.productName),
                onDeleted: viewModel.clearProductFilter,
              ),
            ),
          ),
        Padding(
          padding: spacing.pagePadding,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: Text(l10n.stockBatchesFilterAll),
                  selected:
                      viewModel.batchStatus.isEmpty &&
                      !viewModel.batchExpiredOnly,
                  onSelected: (_) => viewModel.setBatchStatus(''),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: Text(l10n.stockBatchesFilterActive),
                  selected: viewModel.batchStatus == StockBatchStatus.active,
                  onSelected: (_) =>
                      viewModel.setBatchStatus(StockBatchStatus.active),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: Text(l10n.stockBatchesFilterQuarantined),
                  selected:
                      viewModel.batchStatus == StockBatchStatus.quarantined,
                  onSelected: (_) =>
                      viewModel.setBatchStatus(StockBatchStatus.quarantined),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: Text(l10n.stockBatchesFilterExpired),
                  selected: viewModel.batchExpiredOnly,
                  onSelected: viewModel.setBatchExpiredOnly,
                ),
              ],
            ),
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
    // Same reasoning as the units list: the shared component owns the ladder,
    // the skeleton and the load-more trigger, and hand-rolling it is what left
    // a pharmacy able to see only its first fifty lots.
    final spacing = AdaptiveSpacing.of(context);
    return PointyDataList<StockBatch>(
      items: viewModel.batches,
      padding: spacing.pagePadding,
      framed: false,
      isLoadingInitial: viewModel.isLoadingBatches,
      isLoadingMore: viewModel.isLoadingMoreBatches,
      hasMore: viewModel.hasMoreBatches,
      onLoadMore: viewModel.loadMoreBatches,
      hasError: viewModel.hasBatchError,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      errorBuilder: (context) => PointyErrorState(
        title: l10n.stockBatchesTitle,
        icon: Icons.inventory_2_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.loadBatches,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      ),
      emptyBuilder: (context) => PointyEmptyState(
        icon: Icons.inventory_2_outlined,
        title: l10n.stockBatchesEmptyTitle,
        message: l10n.stockBatchesEmptyBody,
      ),
      itemBuilder: (context, batch) => _BatchCard(
        batch: batch,
        onToggleQuarantine: () => _toggleQuarantine(context, batch),
        onOpenRecall: widget.repository == null
            ? null
            : () => _openRecall(context, batch),
      ),
    );
  }

  /// Where this lot came from, where it is, and who has the rest (§6.8.1).
  Future<void> _openRecall(BuildContext context, StockBatch batch) async {
    final repository = widget.repository;
    if (repository == null) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => BatchRecallScreen(
          batch: batch,
          repository: repository,
          canQuarantine: widget.canQuarantine,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    await widget.viewModel.loadBatches();
  }

  Future<void> _toggleQuarantine(BuildContext context, StockBatch batch) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final locking = !batch.isQuarantined;
    if (locking) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.stockBatchQuarantineTitle),
          // Said plainly, because it is one write that reaches every till in
          // every branch at once — which is the point of it, and also the
          // reason it deserves a confirmation.
          content: Text(l10n.stockBatchQuarantineBody(batch.label)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.cancelButton),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.stockBatchQuarantineConfirm),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
    }
    final ok = await widget.viewModel.setQuarantine(batch, locked: locking);
    if (!ok) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.stockBatchQuarantineFailed)),
        );
    }
  }
}

class _BatchCard extends StatelessWidget {
  const _BatchCard({
    required this.batch,
    required this.onToggleQuarantine,
    this.onOpenRecall,
  });

  final StockBatch batch;
  final VoidCallback onToggleQuarantine;
  final VoidCallback? onOpenRecall;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final days = batch.daysUntilExpiry;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    batch.label.isNotEmpty
                        ? batch.label
                        : l10n.stockBatchNoCode,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontStyle: batch.label.isEmpty
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                ),
                if (batch.isQuarantined)
                  Chip(
                    label: Text(l10n.stockBatchQuarantinedBadge),
                    backgroundColor: colors.danger.withValues(alpha: 0.12),
                    labelStyle: theme.textTheme.bodySmall?.copyWith(
                      color: colors.danger,
                    ),
                  ),
              ],
            ),
            if (batch.productName.isNotEmpty)
              Text(
                batch.productName,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.event_outlined,
                  size: 16,
                  color: _expiryTone(context, days),
                ),
                const SizedBox(width: 4),
                Text(
                  batch.expiryDate == null
                      ? l10n.posBatchPickerNoExpiry
                      : formatExpiry(batch.expiryDate!),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _expiryTone(context, days),
                  ),
                ),
                const SizedBox(width: 12),
                Icon(
                  Icons.inventory_outlined,
                  size: 16,
                  color: theme.hintColor,
                ),
                const SizedBox(width: 4),
                Text(
                  formatQuantity(batch.onHand),
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                if (onOpenRecall != null)
                  TextButton(
                    onPressed: onOpenRecall,
                    child: Text(l10n.recallTitle),
                  ),
                TextButton(
                  onPressed: onToggleQuarantine,
                  child: Text(
                    batch.isQuarantined
                        ? l10n.stockBatchReleaseAction
                        : l10n.stockBatchQuarantineAction,
                  ),
                ),
              ],
            ),
            // Where the goods are. The panel the split exists to make possible:
            // one lot, several places, and a recall that can name all of them.
            if (batch.balances.isNotEmpty) ...[
              const Divider(height: 16),
              for (final balance in batch.balances)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(
                        Icons.place_outlined,
                        size: 14,
                        color: theme.hintColor,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          balance.warehouseName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      Text(
                        formatQuantity(balance.remainingQuantity),
                        style: theme.textTheme.bodySmall?.copyWith(
                          // A place it has left still shows, greyed: "Lot A was
                          // in Branch #2 and is not any more" is exactly the
                          // sentence a recall needs.
                          color: balance.isEmpty ? theme.hintColor : null,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Color _expiryTone(BuildContext context, int? days) {
    final colors = context.pointyColors;
    if (days == null) {
      return Theme.of(context).hintColor;
    }
    if (days < 30) {
      return colors.danger;
    }
    if (days < 90) {
      return colors.warning;
    }
    return colors.primaryStrong;
  }
}
