import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/components/components.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/design/design.dart';
import '../../../shared/query_controls/debounced_search_field.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/reorder_view_model.dart';
import 'reorder_row.dart';

/// «إعادة الطلب»: what is at or below its threshold, and what is about to be.
///
/// A work queue rather than a catalog filter, because thresholds and order
/// quantities belong to variants and a catalog row is a product. Pick a
/// supplier, tick what to buy, adjust the suggested quantities, and it becomes
/// a draft purchase order.
class ReorderScreen extends StatefulWidget {
  const ReorderScreen({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.navigation,
    required this.onOpenPurchaseOrder,
    this.showBackButton = false,
  });

  final ReorderViewModel viewModel;
  final ContactRepository contactRepository;
  final AppNavigation navigation;
  final void Function(BuildContext context, PurchaseOrder order)
  onOpenPurchaseOrder;

  /// Opened from the catalog rather than from the navigation: back returns
  /// there instead of the menu opening.
  final bool showBackButton;

  @override
  State<ReorderScreen> createState() => _ReorderScreenState();
}

class _ReorderScreenState extends State<ReorderScreen> {
  ReorderViewModel get viewModel => widget.viewModel;

  @override
  void dispose() {
    viewModel.dispose();
    super.dispose();
  }

  Future<void> _chooseSupplier() async {
    final supplier = await showSupplierPickerSheet(
      context: context,
      repository: widget.contactRepository,
    );
    if (supplier != null && mounted) {
      unawaited(viewModel.setSupplier(id: supplier.id, name: supplier.name));
    }
  }

  Future<void> _createOrder() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final failure = AppLocalizations.of(context)!.reorderCreateOrderError;
    final messenger = ScaffoldMessenger.of(context);
    final order = await viewModel.createOrder();
    if (!mounted) {
      return;
    }
    if (order == null) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(failure)));
      return;
    }
    widget.onOpenPurchaseOrder(context, order);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.reorder,
            navigation: widget.navigation,
          ),
          appBar: PointyAppBar(
            leading: widget.showBackButton
                ? IconButton(
                    tooltip: l10n.backTooltip,
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).maybePop(),
                  )
                : const PointyNavigationMenuButton(),
            title: Text(l10n.reorderTitle),
            isLoading: viewModel.isLoading,
            actions: [
              IconButton(
                tooltip: l10n.refreshCatalogTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: AdaptiveMaxWidth(
            width: AppContentWidth.list,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Filters(
                  viewModel: viewModel,
                  onChooseSupplier: _chooseSupplier,
                ),
                Expanded(child: _Queue(viewModel: viewModel)),
                _Footer(viewModel: viewModel, onCreateOrder: _createOrder),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({required this.viewModel, required this.onChooseSupplier});

  final ReorderViewModel viewModel;
  final VoidCallback onChooseSupplier;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final supplierName = viewModel.supplierName;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.pageHorizontal,
        spacing.pageVertical,
        spacing.pageHorizontal,
        spacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DebouncedSearchField(
            value: viewModel.search,
            hintText: l10n.reorderSearchHint,
            clearTooltip: l10n.clearSearchTooltip,
            onChanged: viewModel.setSearch,
          ),
          SizedBox(height: spacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('reorder_supplier_button'),
                onPressed: onChooseSupplier,
                icon: const Icon(Icons.local_shipping_outlined),
                label: Text(supplierName ?? l10n.reorderChooseSupplier),
              ),
              if (supplierName != null)
                IconButton(
                  key: const ValueKey('reorder_clear_supplier'),
                  tooltip: l10n.clearSupplierFilterTooltip,
                  icon: const Icon(Icons.close),
                  onPressed: () => viewModel.setSupplier(),
                ),
              Tooltip(
                message: l10n.reorderApproachingHint,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      key: const ValueKey('reorder_approaching_switch'),
                      value: viewModel.includeApproaching,
                      onChanged: viewModel.setIncludeApproaching,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        l10n.reorderApproachingLabel,
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(color: colors.ink),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Queue extends StatelessWidget {
  const _Queue({required this.viewModel});

  final ReorderViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final horizontal = EdgeInsets.symmetric(horizontal: spacing.pageHorizontal);

    if (viewModel.hasError) {
      return PointyEmptyState(
        icon: Icons.cloud_off_outlined,
        title: l10n.reorderLoadError,
        action: FilledButton(
          onPressed: viewModel.load,
          child: Text(l10n.retryButton),
        ),
      );
    }
    if (viewModel.isEmptyQueue) {
      if (viewModel.isLoading) {
        return const Center(child: PointySpinner());
      }
      return PointyEmptyState(
        icon: Icons.task_alt,
        title: viewModel.supplierId == null
            ? l10n.reorderEmptyTitle
            : l10n.reorderEmptySupplierTitle,
        message: l10n.reorderEmptyMessage,
      );
    }
    final rows = viewModel.visibleRows;
    if (rows.isEmpty) {
      return PointyEmptyState(
        icon: Icons.search_off,
        title: l10n.catalogNoSearchResultsTitle(viewModel.search.trim()),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final tableLayout =
            constraints.maxWidth - spacing.pageHorizontal * 2 >=
            ReorderColumns.tableMinWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (viewModel.hiddenCount > 0)
              Padding(
                padding: horizontal.copyWith(bottom: spacing.sm),
                child: PointyInlineMessage(
                  compact: true,
                  message: l10n.reorderMoreRowsHidden(viewModel.hiddenCount),
                ),
              ),
            Padding(
              padding: horizontal,
              child: tableLayout
                  ? ReorderHeaderRow(
                      allSelected: viewModel.allVisibleSelected,
                      onToggleAll: viewModel.toggleAllVisible,
                    )
                  : Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        key: const ValueKey('reorder_select_all'),
                        onPressed: viewModel.toggleAllVisible,
                        icon: Icon(
                          viewModel.allVisibleSelected
                              ? Icons.deselect_outlined
                              : Icons.select_all,
                        ),
                        label: Text(
                          viewModel.allVisibleSelected
                              ? l10n.bulkClearSelectionAction
                              : l10n.bulkSelectAllAction,
                        ),
                      ),
                    ),
            ),
            Expanded(
              child: ListView.separated(
                padding: horizontal.copyWith(bottom: spacing.md),
                itemCount: rows.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final row = rows[index];
                  return ReorderRowTile(
                    row: row,
                    selected: viewModel.isSelected(row),
                    quantity: viewModel.quantityOf(row),
                    tableLayout: tableLayout,
                    onToggle: () => viewModel.toggle(row),
                    onQuantityChanged: (quantity) =>
                        viewModel.setQuantity(row, quantity),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.viewModel, required this.onCreateOrder});

  final ReorderViewModel viewModel;
  final VoidCallback onCreateOrder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final count = viewModel.selectedCount;
    return PointyStickyActionFooter(
      summary: Text(
        viewModel.supplierId == null
            ? l10n.reorderSupplierRequiredHint
            : l10n.bulkSelectedCount(count),
      ),
      primaryAction: FilledButton.icon(
        key: const ValueKey('reorder_create_order'),
        onPressed: viewModel.canCreateOrder ? onCreateOrder : null,
        icon: viewModel.isCreating
            ? const SizedBox.square(
                dimension: 18,
                child: PointySpinner(strokeWidth: 2),
              )
            : const Icon(Icons.add_shopping_cart),
        label: Text(l10n.reorderCreateOrderAction),
      ),
    );
  }
}
