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
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/units.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/product_status_pill.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/product_stock_view_model.dart';
import 'barcode_label_print_action.dart';
import 'product_details_hero.dart';
import 'variant_cost_metrics.dart';
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
    final product = viewModel.product;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: Text(l10n.variantDetailsTitle)),
          body: SafeArea(
            child: AdaptiveMaxWidth(
              width: AppContentWidth.detail,
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
                    child: PointyMetricGrid(
                      maxColumns: 2,
                      minTileWidth: 200,
                      gap: PointyMetricGridGap.compact,
                      metrics: [
                        PointyMetricGridItem(
                          label: l10n.skuLabel,
                          value: product.effectiveSku,
                          icon: Icons.tag_outlined,
                        ),
                        PointyMetricGridItem(
                          label: l10n.barcodeLabel,
                          value: product.effectiveBarcode.isEmpty
                              ? l10n.noBarcode
                              : product.effectiveBarcode,
                          icon: Icons.qr_code_2,
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
                  if (viewModel.variantCostSummary != null) ...[
                    const SizedBox(height: 12),
                    PointyDetailSection(
                      title: l10n.productCostOverviewTitle,
                      icon: Icons.payments_outlined,
                      child: VariantCostMetrics.fromSummary(
                        viewModel.variantCostSummary!,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  PointyDetailSection(
                    title: l10n.productCostHistoryTitle,
                    icon: Icons.trending_up_outlined,
                    child: _ProductCostHistorySection(viewModel: viewModel),
                  ),
                ],
              ),
            ),
          ),
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
      return const Center(child: PointySpinner());
    }
    if (viewModel.hasCostInsightsError && impact == null && entries.isEmpty) {
      return PointyInlineMessage.error(
        message: l10n.productCostHistoryLoadError,
      );
    }

    if (impact == null && entries.isEmpty) {
      return PointyEmptyState(
        icon: Icons.trending_up_outlined,
        title: l10n.productCostHistoryEmpty,
      );
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
                      l10n.purchaseOrderLineQuantity(
                        formatQuantity(entry.quantity),
                      ),
                      // A pack row carries its pack price for reference; the
                      // trailing figure stays per base unit so a carton row
                      // doesn't read as a 30× cost spike next to piece rows.
                      if (entry.isPackPurchase &&
                          (entry.unitLabel?.isNotEmpty ?? false))
                        l10n.productCostHistoryPackCost(
                          formatMoney(
                            entry.effectiveUnitCost ?? entry.unitCost,
                          ),
                          entry.unitLabel!,
                        ),
                      if (entry.recordedAt != null)
                        formatDate(entry.recordedAt!),
                    ].join(' • '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    formatMoney(entry.displayBaseUnitCost),
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
    final colors = context.pointyColors;
    final costChange = impact.costChange;
    final marginChange = impact.marginChangePercent;

    return PointyMetricGrid(
      maxColumns: 3,
      minTileWidth: 150,
      gap: PointyMetricGridGap.compact,
      metrics: [
        PointyMetricGridItem(
          label: l10n.productLatestCostLabel,
          value: latestCost == null
              ? l10n.shopSettingsEmptyValue
              : formatMoney(latestCost),
          icon: Icons.inventory_2_outlined,
        ),
        PointyMetricGridItem(
          label: l10n.unitPriceLabel,
          value: formatMoney(unitPrice),
          icon: Icons.sell_outlined,
        ),
        PointyMetricGridItem(
          label: l10n.productGrossProfitLabel,
          value: grossProfit == null
              ? l10n.shopSettingsEmptyValue
              : formatMoney(grossProfit),
          icon: Icons.trending_up_outlined,
          accentColor: grossProfit == null
              ? null
              : (grossProfit >= 0 ? colors.success : colors.danger),
        ),
        PointyMetricGridItem(
          label: l10n.productMarginPercentLabel,
          value: marginPercent == null
              ? l10n.shopSettingsEmptyValue
              : l10n.productMarginPercentValue(
                  _formatSignedPercent(
                    marginPercent,
                    includePositiveSign: false,
                  ),
                ),
          icon: Icons.percent,
          accentColor: marginPercent == null
              ? null
              : (marginPercent >= 0 ? colors.success : colors.danger),
        ),
        if (costChange != null)
          PointyMetricGridItem(
            label: l10n.productCostChangeLabel,
            value: _formatSignedMoney(costChange),
            icon: Icons.price_change_outlined,
            accentColor: costChange > 0
                ? colors.danger
                : (costChange < 0 ? colors.success : null),
          ),
        if (marginChange != null)
          PointyMetricGridItem(
            label: l10n.productMarginChangeLabel,
            value: l10n.productMarginPercentValue(
              _formatSignedPercent(marginChange),
            ),
            icon: Icons.show_chart_outlined,
            accentColor: marginChange > 0
                ? colors.success
                : (marginChange < 0 ? colors.danger : null),
          ),
      ],
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
    final variant = product.defaultVariant;
    final label = variant == null
        ? BarcodeLabelDraft.fromProduct(product)
        : BarcodeLabelDraft.fromVariant(variant);
    final hasBarcode = label.barcode.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!hasBarcode) ...[
          PointyInlineMessage.error(message: l10n.barcodeLabelPrintNoBarcode),
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
            const PointyProgressBar()
          else if (viewModel.errorMessage == 'stock_load_error')
            PointyInlineMessage.error(message: l10n.stockLoadError)
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
    final colors = context.pointyColors;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: Border.all(color: colors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: colors.primaryContainer,
              foregroundColor: colors.primaryStrong,
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
                color: colors.primaryStrong,
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
