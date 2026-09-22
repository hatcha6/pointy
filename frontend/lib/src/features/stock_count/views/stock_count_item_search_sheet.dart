import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_variant.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/stock_count_item_search_view_model.dart';
import 'stock_count_search_panel.dart';

/// "What is this thing?" — the picker for a code nothing in the shop answers
/// to. Returns the selected variant or null on dismiss.
///
/// This is the ONE place the count still opens a search in a sheet, because the
/// question is modal by nature: an unidentified article is in the counter's
/// hand and the answer attaches to that scan. The resting search lives inline
/// on the counting screen ([StockCountSearchPanel]).
Future<ProductVariant?> showStockCountItemSearchSheet(
  BuildContext context, {
  required CatalogRepository catalogRepository,
}) {
  return showAdaptiveModalBottomSheet<ProductVariant>(
    context: context,
    builder: (context) =>
        _ItemSearchSheet(catalogRepository: catalogRepository),
  );
}

class _ItemSearchSheet extends StatefulWidget {
  const _ItemSearchSheet({required this.catalogRepository});

  final CatalogRepository catalogRepository;

  @override
  State<_ItemSearchSheet> createState() => _ItemSearchSheetState();
}

class _ItemSearchSheetState extends State<_ItemSearchSheet> {
  late final StockCountItemSearchViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = StockCountItemSearchViewModel(widget.catalogRepository)
      ..search('');
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      // The soft keyboard opens the moment this sheet does (the field takes
      // focus), and a modal bottom sheet is NOT inset for it — without this the
      // list the counter is meant to pick from sits behind the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(0, spacing.xs, 0, spacing.md),
        child: ListenableBuilder(
          listenable: _viewModel,
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsetsDirectional.symmetric(
                    horizontal: spacing.lg,
                  ),
                  child: Text(
                    l10n.stockCountSearchItem,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                // A bounded height: the results list must be allowed to scroll
                // inside the sheet rather than push it past the screen.
                Flexible(
                  child: StockCountSearchPanel(
                    term: _viewModel.term,
                    results: _viewModel.results,
                    isLoading: _viewModel.isLoading,
                    hasError: _viewModel.hasError,
                    hasMore: _viewModel.hasMore,
                    onSearch: _viewModel.search,
                    onLoadMore: _viewModel.loadMore,
                    onRetry: _viewModel.retry,
                    onPick: (variant) => Navigator.of(context).pop(variant),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
