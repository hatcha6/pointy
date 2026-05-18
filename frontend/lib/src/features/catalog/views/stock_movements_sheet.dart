import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/stock_movement.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../view_models/product_stock_view_model.dart';
import 'stock_movement_labels.dart';

class StockMovementsSheet extends StatelessWidget {
  const StockMovementsSheet({
    super.key,
    required this.viewModel,
    required this.capabilities,
    required this.onCreateMovement,
    required this.onClose,
  });

  final ProductStockViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onCreateMovement;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return StockViewGuard(
          capabilities: capabilities,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.list_alt_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.stockMovementsTitle,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            viewModel.product.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                StockMovementCreateGuard(
                  capabilities: capabilities,
                  child: FilledButton.icon(
                    onPressed: onCreateMovement,
                    icon: const Icon(Icons.add_chart_outlined),
                    label: Text(l10n.newStockMovementButton),
                  ),
                ),
                if (viewModel.errorMessage == 'stock_movement_load_error') ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.stockMovementLoadError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Expanded(
                  child: InfiniteScrollList<StockMovement>(
                    items: viewModel.movements,
                    onLoadMore: viewModel.loadMoreMovements,
                    hasMore: viewModel.hasMoreMovements,
                    isLoadingInitial: viewModel.isLoadingMovements,
                    isLoadingMore: viewModel.isLoadingMoreMovements,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    emptyBuilder: (context) =>
                        Center(child: Text(l10n.emptyStockMovements)),
                    itemBuilder: (context, movement) {
                      return _StockMovementTile(movement: movement);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StockMovementTile extends StatelessWidget {
  const _StockMovementTile({required this.movement});

  final StockMovement movement;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final date = movement.createdAt == null
        ? ''
        : formatDateTime(movement.createdAt!);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  _movementIcon(movement.movementType),
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    stockMovementTypeLabel(l10n, movement.movementType),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  l10n.stockMovementQuantityValue(movement.quantity),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _SnapshotChip(
                  label: l10n.stockOnHandLabel,
                  before: movement.onHandBefore,
                  after: movement.onHandAfter,
                ),
              ],
            ),
            if (movement.note.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(movement.note),
            ],
            if (date.isNotEmpty || movement.createdByName != null) ...[
              const SizedBox(height: 10),
              Text(
                [
                  if (date.isNotEmpty) date,
                  if (movement.createdByName != null) movement.createdByName!,
                ].join(' / '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _movementIcon(StockMovementType movementType) {
    return switch (movementType) {
      StockMovementType.increase => Icons.add_circle_outline,
      StockMovementType.decrease => Icons.remove_circle_outline,
      StockMovementType.damaged => Icons.broken_image_outlined,
    };
  }
}

class _SnapshotChip extends StatelessWidget {
  const _SnapshotChip({
    required this.label,
    required this.before,
    required this.after,
  });

  final String label;
  final int before;
  final int after;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: const Icon(Icons.timeline, size: 18),
      label: Text('$label: $before -> $after'),
    );
  }
}
