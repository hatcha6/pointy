import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../data/models/barcode_label.dart';
import '../../../data/models/product.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/product_status_pill.dart';
import '../view_models/product_stock_view_model.dart';
import 'barcode_label_print_action.dart';
import 'product_details_hero.dart';
import 'stock_movement_form.dart';
import 'stock_movements_sheet.dart';

class ProductVariantDetailsScreen extends StatelessWidget {
  const ProductVariantDetailsScreen({
    super.key,
    required this.viewModel,
    required this.printingRepository,
    required this.capabilities,
    this.analyticsEngine,
  });

  final ProductStockViewModel viewModel;
  final PrintingRepository printingRepository;
  final AuthorizationCapabilities capabilities;
  final AnalyticsEngine? analyticsEngine;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final product = viewModel.product;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: Text(l10n.variantDetailsTitle)),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ProductDetailsHero(product: product),
                const SizedBox(height: 16),
                StockViewGuard(
                  capabilities: capabilities,
                  child: _StockSummarySection(
                    viewModel: viewModel,
                    capabilities: capabilities,
                    onCreateMovement: () => _showMovementForm(context),
                    onOpenMovements: () => _openMovements(context),
                  ),
                ),
                if (capabilities.canViewStock) const SizedBox(height: 12),
                PointyDetailSection(
                  title: l10n.productAvailabilityTitle,
                  icon: product.isActive
                      ? Icons.check_circle_outline
                      : Icons.pause_circle_outline,
                  child: Row(
                    children: [
                      ProductStatusPill(isActive: product.isActive),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          product.isActive
                              ? l10n.productAvailableForSale
                              : l10n.productUnavailableForSale,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                PointyDetailSection(
                  title: l10n.productIdentifierTitle,
                  icon: Icons.qr_code_2,
                  child: Column(
                    children: [
                      PointyDetailRow(
                        label: l10n.skuLabel,
                        value: product.effectiveSku,
                      ),
                      const Divider(height: 20),
                      PointyDetailRow(
                        label: l10n.barcodeLabel,
                        value: product.effectiveBarcode.isEmpty
                            ? l10n.noBarcode
                            : product.effectiveBarcode,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                PointyDetailSection(
                  title: l10n.barcodeLabelPrintTitle,
                  icon: Icons.print_outlined,
                  child: _BarcodeLabelPrintSection(
                    product: product,
                    printingRepository: printingRepository,
                    analyticsEngine: analyticsEngine,
                  ),
                ),
                const SizedBox(height: 12),
                PointyDetailSection(
                  title: l10n.productDescriptionTitle,
                  icon: Icons.notes_outlined,
                  child: Text(
                    product.description.isEmpty
                        ? l10n.noDescription
                        : product.description,
                  ),
                ),
                const SizedBox(height: 12),
                PointyDetailSection(
                  title: l10n.productCostHistoryTitle,
                  icon: Icons.trending_up_outlined,
                  child: _ProductCostHistorySection(viewModel: viewModel),
                ),
              ],
            ),
          ),
          backgroundColor: colorScheme.surface,
        );
      },
    );
  }

  Future<void> _showMovementForm(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: StockMovementForm(
            viewModel: viewModel,
            onSaved: () => Navigator.of(sheetContext).pop(),
          ),
        );
      },
    );
  }

  Future<void> _openMovements(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return FractionallySizedBox(
          heightFactor: 0.9,
          child: StockMovementsSheet(
            viewModel: viewModel,
            capabilities: capabilities,
            onCreateMovement: () => _showMovementForm(sheetContext),
            onClose: () => Navigator.of(sheetContext).pop(),
          ),
        );
      },
    );
  }
}

class _ProductCostHistorySection extends StatelessWidget {
  const _ProductCostHistorySection({required this.viewModel});

  final ProductStockViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final impact = viewModel.marginImpact;
    final entries = viewModel.costHistory;

    if (viewModel.isLoadingCostInsights && impact == null && entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (viewModel.hasCostInsightsError && impact == null && entries.isEmpty) {
      return Text(
        l10n.productCostHistoryLoadError,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }

    if (impact == null && entries.isEmpty) {
      return Text(l10n.productCostHistoryEmpty);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (impact != null) ...[
          _MarginImpactGrid(
            impact: impact,
            fallbackPrice: viewModel.product.effectiveUnitPrice,
          ),
          if (entries.isNotEmpty) const Divider(height: 24),
        ],
        if (entries.isNotEmpty)
          SizedBox(
            height: _costHistoryListHeight(
              entries.length,
              viewModel.hasMoreCostHistory,
            ),
            child: InfiniteScrollList<ProductCostHistoryEntry>(
              items: entries,
              onLoadMore: viewModel.loadMoreCostHistory,
              hasMore: viewModel.hasMoreCostHistory,
              isLoadingInitial: viewModel.isLoadingCostInsights,
              isLoadingMore: viewModel.isLoadingMoreCostHistory,
              emptyBuilder: (context) => Text(l10n.productCostHistoryEmpty),
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, entry) {
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: Text(
                    entry.supplierName?.isNotEmpty == true
                        ? entry.supplierName!
                        : l10n.noSupplierSelectedLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      if (entry.purchaseOrderNumber != null &&
                          entry.purchaseOrderNumber!.isNotEmpty)
                        l10n.purchaseOrderNumberValue(
                          entry.purchaseOrderNumber!,
                        ),
                      l10n.purchaseOrderLineQuantity(entry.quantity),
                      if (entry.recordedAt != null)
                        formatDate(entry.recordedAt!),
                    ].join(' • '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    formatMoney(entry.effectiveUnitCost ?? entry.unitCost),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

double _costHistoryListHeight(int itemCount, bool hasMore) {
  if (hasMore || itemCount > 4) {
    return 288;
  }
  if (itemCount == 1) {
    return 72;
  }
  if (itemCount == 2) {
    return 144;
  }
  if (itemCount == 3) {
    return 216;
  }
  return 288;
}

class _MarginImpactGrid extends StatelessWidget {
  const _MarginImpactGrid({required this.impact, required this.fallbackPrice});

  final ProductMarginImpact impact;
  final double fallbackPrice;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final unitPrice = impact.unitPrice > 0 ? impact.unitPrice : fallbackPrice;
    final latestCost = impact.latestEffectiveUnitCost ?? impact.latestUnitCost;
    final grossProfit =
        impact.grossProfit ??
        (latestCost == null ? null : unitPrice - latestCost);
    final marginPercent =
        impact.marginPercent ??
        (grossProfit == null || unitPrice <= 0
            ? null
            : (grossProfit / unitPrice) * 100);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _MetricChip(
          label: l10n.productLatestCostLabel,
          value: latestCost == null
              ? l10n.shopSettingsEmptyValue
              : formatMoney(latestCost),
        ),
        _MetricChip(label: l10n.unitPriceLabel, value: formatMoney(unitPrice)),
        _MetricChip(
          label: l10n.productGrossProfitLabel,
          value: grossProfit == null
              ? l10n.shopSettingsEmptyValue
              : formatMoney(grossProfit),
        ),
        _MetricChip(
          label: l10n.productMarginPercentLabel,
          value: marginPercent == null
              ? l10n.shopSettingsEmptyValue
              : l10n.productMarginPercentValue(
                  _formatSignedPercent(
                    marginPercent,
                    includePositiveSign: false,
                  ),
                ),
        ),
        if (impact.costChange != null)
          _MetricChip(
            label: l10n.productCostChangeLabel,
            value: _formatSignedMoney(impact.costChange!),
          ),
        if (impact.marginChangePercent != null)
          _MetricChip(
            label: l10n.productMarginChangeLabel,
            value: l10n.productMarginPercentValue(
              _formatSignedPercent(impact.marginChangePercent!),
            ),
          ),
      ],
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 2),
            Text(value, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
      ),
    );
  }
}

class _BarcodeLabelPrintSection extends StatelessWidget {
  const _BarcodeLabelPrintSection({
    required this.product,
    required this.printingRepository,
    this.analyticsEngine,
  });

  final Product product;
  final PrintingRepository printingRepository;
  final AnalyticsEngine? analyticsEngine;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final variant = product.defaultVariant;
    final label = variant == null
        ? BarcodeLabelDraft.fromProduct(product)
        : BarcodeLabelDraft.fromVariant(variant);
    final hasBarcode = label.barcode.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!hasBarcode) ...[
          Text(
            l10n.barcodeLabelPrintNoBarcode,
            style: TextStyle(color: colorScheme.error),
          ),
          const SizedBox(height: 12),
        ],
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: BarcodeLabelPrintButton(
            width: 240,
            label: label,
            printingRepository: printingRepository,
            productId: product.id,
            productName: label.productName.isEmpty
                ? product.name
                : label.productName,
            variantId: variant?.id,
            entityType: variant == null ? 'product' : 'product_variant',
            entityId: variant?.id ?? product.id,
            source: 'barcode_label_panel',
            tracksExpiry:
                product.tracksExpiry || (variant?.tracksExpiry ?? false),
            analyticsEngine: analyticsEngine,
            tooltip: l10n.barcodeLabelPrintButton,
          ),
        ),
      ],
    );
  }
}

class _StockSummarySection extends StatelessWidget {
  const _StockSummarySection({
    required this.viewModel,
    required this.capabilities,
    required this.onCreateMovement,
    required this.onOpenMovements,
  });

  final ProductStockViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onCreateMovement;
  final VoidCallback onOpenMovements;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailSection(
      title: l10n.stockSummaryTitle,
      icon: Icons.inventory_2_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (viewModel.isLoadingStock)
            const LinearProgressIndicator()
          else if (viewModel.errorMessage == 'stock_load_error')
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                l10n.stockLoadError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            )
          else
            _StockOnHandPanel(
              label: l10n.stockOnHandLabel,
              value: viewModel.quantityOnHand,
            ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StockMovementCreateGuard(
                capabilities: capabilities,
                child: SizedBox(
                  width: 220,
                  child: FilledButton.icon(
                    onPressed: onCreateMovement,
                    icon: const Icon(Icons.add_chart_outlined),
                    label: Text(l10n.newStockMovementButton),
                  ),
                ),
              ),
              SizedBox(
                width: 220,
                child: OutlinedButton.icon(
                  onPressed: onOpenMovements,
                  icon: const Icon(Icons.list_alt_outlined),
                  label: Text(l10n.stockMovementsButton),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StockOnHandPanel extends StatelessWidget {
  const _StockOnHandPanel({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: colorScheme.primaryContainer,
              foregroundColor: colorScheme.onPrimaryContainer,
              child: const Icon(Icons.inventory_outlined),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Text(
              '$value',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatSignedMoney(double value) {
  final amount = formatMoney(value.abs());
  if (value > 0) {
    return '+$amount';
  }
  if (value < 0) {
    return '-$amount';
  }
  return amount;
}

String _formatSignedPercent(double value, {bool includePositiveSign = true}) {
  final amount = value.abs().toStringAsFixed(2);
  if (value > 0 && includePositiveSign) {
    return '+$amount';
  }
  if (value < 0) {
    return '-$amount';
  }
  return amount;
}
