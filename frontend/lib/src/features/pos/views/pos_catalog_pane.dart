import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/barcode_capture_controller.dart';
import '../../../shared/barcode/barcode_capture_field.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/product_query_controls.dart';
import '../../../shared/product_tile.dart';
import '../view_models/pos_view_model.dart';

class PosCatalogPane extends StatefulWidget {
  const PosCatalogPane({
    super.key,
    required this.viewModel,
    required this.capabilities,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  State<PosCatalogPane> createState() => _PosCatalogPaneState();
}

class _PosCatalogPaneState extends State<PosCatalogPane> {
  final BarcodeCaptureController _barcodeController =
      BarcodeCaptureController();

  @override
  void dispose() {
    _barcodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final viewModel = widget.viewModel;
    final capabilities = widget.capabilities;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l10n.catalogTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              if (viewModel.isLoading)
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (viewModel.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l10n.sampleCatalogNotice,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
            ),
          const SizedBox(height: 12),
          CheckoutCapabilityBuilder(
            capabilities: capabilities,
            builder: (context, canCheckout) {
              return BarcodeCaptureField(
                controller: _barcodeController,
                labelText: l10n.posBarcodeFieldLabel,
                hintText: l10n.posBarcodeFieldHint,
                clearTooltip: l10n.clearBarcodeTooltip,
                focusTooltip: l10n.focusBarcodeTooltip,
                enabled:
                    canCheckout &&
                    !viewModel.isCheckingOut &&
                    !viewModel.isResolvingBarcode,
                autofocus: true,
                onSubmitted: viewModel.addProductByBarcode,
              );
            },
          ),
          if (viewModel.barcodeScanStatus != BarcodeScanStatus.idle) ...[
            const SizedBox(height: 8),
            _BarcodeScanStatusLine(viewModel: viewModel),
          ],
          const SizedBox(height: 12),
          ProductQueryControls(
            query: viewModel.query,
            allowAvailabilityFilter: false,
            onSearchChanged: viewModel.updateSearch,
            onQueryChanged: viewModel.applyQuery,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: InfiniteScrollGrid(
              items: viewModel.products,
              onLoadMore: viewModel.loadMoreCatalog,
              hasMore: viewModel.hasMoreProducts,
              isLoadingInitial: viewModel.isLoading,
              isLoadingMore: viewModel.isLoadingMore,
              emptyBuilder: (context) => Center(child: Text(l10n.emptyCatalog)),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisExtent: 156,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemBuilder: (context, product) {
                return CheckoutCapabilityBuilder(
                  capabilities: capabilities,
                  builder: (context, canCheckout) {
                    return ProductTile(
                      product: product,
                      onTap: canCheckout
                          ? () => viewModel.addProduct(product)
                          : null,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _BarcodeScanStatusLine extends StatelessWidget {
  const _BarcodeScanStatusLine({required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final status = viewModel.barcodeScanStatus;
    final message = switch (status) {
      BarcodeScanStatus.resolving => l10n.barcodeScanResolving,
      BarcodeScanStatus.found => l10n.barcodeScanAdded(
        viewModel.lastScannedProductName ?? '',
      ),
      BarcodeScanStatus.notFound => l10n.barcodeScanNotFound(
        viewModel.lastScannedBarcode ?? '',
      ),
      BarcodeScanStatus.error => l10n.barcodeScanError,
      BarcodeScanStatus.idle => '',
    };
    final color = switch (status) {
      BarcodeScanStatus.found => colorScheme.primary,
      BarcodeScanStatus.notFound ||
      BarcodeScanStatus.error => colorScheme.error,
      BarcodeScanStatus.resolving ||
      BarcodeScanStatus.idle => colorScheme.onSurfaceVariant,
    };

    return Row(
      children: [
        if (status == BarcodeScanStatus.resolving)
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Icon(
            status == BarcodeScanStatus.found
                ? Icons.check_circle_outline
                : Icons.error_outline,
            size: 18,
            color: color,
          ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
        IconButton(
          tooltip: l10n.clearBarcodeStatusTooltip,
          onPressed: viewModel.clearBarcodeScanStatus,
          icon: const Icon(Icons.close),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
