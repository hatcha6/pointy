import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/detail_section.dart';
import '../../../shared/product_status_pill.dart';
import '../view_models/product_stock_view_model.dart';
import 'product_details_hero.dart';
import 'stock_movement_form.dart';
import 'stock_movements_sheet.dart';

class ProductDetailsScreen extends StatelessWidget {
  const ProductDetailsScreen({
    super.key,
    required this.viewModel,
    required this.capabilities,
  });

  final ProductStockViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final product = viewModel.product;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: Text(l10n.productDetailsTitle)),
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
                DetailSection(
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
                DetailSection(
                  title: l10n.productIdentifierTitle,
                  icon: Icons.qr_code_2,
                  child: Column(
                    children: [
                      DetailRow(label: l10n.skuLabel, value: product.sku),
                      const Divider(height: 20),
                      DetailRow(
                        label: l10n.barcodeLabel,
                        value: product.barcode.isEmpty
                            ? l10n.noBarcode
                            : product.barcode,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                DetailSection(
                  title: l10n.productDescriptionTitle,
                  icon: Icons.notes_outlined,
                  child: Text(
                    product.description.isEmpty
                        ? l10n.noDescription
                        : product.description,
                  ),
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

    return DetailSection(
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
