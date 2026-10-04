import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/customer_asset.dart';
import '../../../data/models/product.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/tracking/tracking_labels.dart';
import '../../inventory/view_models/tracked_stock_view_model.dart';
import '../../inventory/views/stock_batches_screen.dart';
import '../../inventory/views/stock_units_screen.dart';

/// How a tracked product's stock is identified, on the product's own page —
/// and the way to the articles and lots themselves.
///
/// Absent for every product that is counted rather than identified, which is
/// nearly every product in nearly every shop.
class ProductTrackingCard extends StatefulWidget {
  const ProductTrackingCard({
    super.key,
    required this.product,
    required this.capabilities,
    required this.catalogRepository,
    this.trackedStockRepository,
  });

  final Product product;
  final AuthorizationCapabilities capabilities;
  final CatalogRepository catalogRepository;

  /// What the two buttons open. Without it the card still says how the
  /// product is tracked.
  final TrackedStockRepository? trackedStockRepository;

  @override
  State<ProductTrackingCard> createState() => _ProductTrackingCardState();
}

class _ProductTrackingCardState extends State<ProductTrackingCard> {
  String _assetTypeName = '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadAssetTypeName());
  }

  @override
  void didUpdateWidget(covariant ProductTrackingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.product.assetTypeId != widget.product.assetTypeId) {
      unawaited(_loadAssetTypeName());
    }
  }

  /// The product stores the kind's id; its name is the shop's own list.
  Future<void> _loadAssetTypeName() async {
    final id = widget.product.assetTypeId;
    if (id == null || !widget.product.trackingMode.tracksUnits) {
      if (_assetTypeName.isNotEmpty) {
        setState(() => _assetTypeName = '');
      }
      return;
    }
    final result = await widget.catalogRepository.loadAssetTypes();
    if (!mounted) {
      return;
    }
    if (result case Ok<List<CustomerAssetType>>(:final value)) {
      setState(() {
        _assetTypeName =
            value.where((type) => type.id == id).firstOrNull?.name ?? '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final product = widget.product;
    final mode = product.trackingMode;
    final repository = widget.trackedStockRepository;
    final canOpenUnits =
        repository != null &&
        mode.tracksUnits &&
        widget.capabilities.canViewStockUnits;
    final canOpenLots =
        repository != null &&
        mode.tracksLots &&
        widget.capabilities.canViewStockBatches;

    return PointyDetailSection(
      title: l10n.productTrackingSectionTitle,
      icon: trackingModeIcon(mode),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointySummaryList(
            rows: [
              PointySummaryRow(
                label: l10n.productTrackingModeLabel,
                value: trackingModeLabel(l10n, mode),
                emphasized: true,
              ),
              if (mode.tracksUnits && _assetTypeName.isNotEmpty)
                PointySummaryRow(
                  label: l10n.productTrackingAssetTypeLabel,
                  value: _assetTypeName,
                ),
              if (mode.tracksUnits)
                PointySummaryRow(
                  label: l10n.productTrackingWarrantyCardLabel,
                  value: product.warrantyDays > 0
                      ? l10n.productTrackingWarrantyDays(product.warrantyDays)
                      : l10n.productTrackingNoWarranty,
                ),
              if (mode.tracksLots) ...[
                PointySummaryRow(
                  label: l10n.batchPickStrategyLabel,
                  value: batchPickStrategyLabel(l10n, product.autoPickStrategy),
                ),
                PointySummaryRow(
                  label: l10n.productTrackingPreventExpiredLabel,
                  value: product.preventSellingExpired
                      ? l10n.productTrackingYes
                      : l10n.productTrackingNo,
                ),
              ],
            ],
          ),
          if (canOpenUnits || canOpenLots) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (canOpenUnits)
                  OutlinedButton.icon(
                    key: const ValueKey('product_tracking_open_units'),
                    onPressed: () => _openUnits(context, repository),
                    icon: const Icon(Icons.qr_code_2_outlined),
                    label: Text(l10n.productTrackingOpenUnits),
                  ),
                if (canOpenLots)
                  OutlinedButton.icon(
                    key: const ValueKey('product_tracking_open_lots'),
                    onPressed: () => _openLots(context, repository),
                    icon: const Icon(Icons.event_available_outlined),
                    label: Text(l10n.productTrackingOpenLots),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// A list of this product's articles, on a view model of its own: the
  /// app-wide one behind the drawer entry must not come back filtered.
  Future<void> _openUnits(
    BuildContext context,
    TrackedStockRepository repository,
  ) async {
    final viewModel = TrackedStockViewModel(repository)
      ..setProductFilter(widget.product.id, name: widget.product.name);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StockUnitsScreen(
          viewModel: viewModel,
          capabilities: widget.capabilities,
          repository: repository,
        ),
      ),
    );
    viewModel.dispose();
  }

  Future<void> _openLots(
    BuildContext context,
    TrackedStockRepository repository,
  ) async {
    final viewModel = TrackedStockViewModel(repository)
      ..setProductFilter(widget.product.id, name: widget.product.name);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StockBatchesScreen(
          viewModel: viewModel,
          repository: repository,
          canQuarantine: widget.capabilities.canQuarantineBatch,
          canIdentify: widget.capabilities.canIdentifyStockUnits,
        ),
      ),
    );
    viewModel.dispose();
  }
}
