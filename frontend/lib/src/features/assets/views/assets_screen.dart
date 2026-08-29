import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/customer_asset.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/query_controls/debounced_search_field.dart';
import '../../../shared/query_controls/query_empty_state.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/assets_view_model.dart';
import 'assets_ui.dart';

/// The registry of customer property — phones, laptops, cars.
///
/// Search-first on purpose: this screen exists to answer one question a counter
/// asks dozens of times a day — "have we seen this thing before?" — from a
/// chassis number, a plate, an IMEI or a serial. The field takes resting focus
/// and every identity number the shop knows is behind it.
class AssetsScreen extends StatefulWidget {
  const AssetsScreen({
    super.key,
    required this.viewModel,
    required this.capabilities,
    required this.navigation,
    required this.onOpenAsset,
  });

  final AssetsViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;
  final void Function(CustomerAsset asset) onOpenAsset;

  @override
  State<AssetsScreen> createState() => _AssetsScreenState();
}

class _AssetsScreenState extends State<AssetsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.viewModel.load();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = widget.viewModel;

        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.assets,
            navigation: widget.navigation,
          ),
          appBar: PointyAppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.assetsTitle),
            isLoading: viewModel.isLoading,
            reserveLoadingSlot: false,
            actions: [
              IconButton(
                tooltip: l10n.refreshJobsTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: _body(context, l10n),
        );
      },
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.hasLoadError && viewModel.assets.isEmpty) {
      return PointyErrorState(
        title: l10n.assetsLoadError,
        icon: Icons.devices_other_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            spacing.pageHorizontal,
            spacing.sm,
            spacing.pageHorizontal,
            spacing.xs,
          ),
          child: AdaptiveMaxWidth(
            width: AppContentWidth.list,
            child: _SearchAndFilters(viewModel: viewModel),
          ),
        ),
        Expanded(
          child: InfiniteScrollList<CustomerAsset>(
            items: viewModel.assets,
            padding: spacing.pagePadding,
            isLoadingInitial: viewModel.isLoading && viewModel.assets.isEmpty,
            isLoadingMore: viewModel.isLoadingMore,
            hasMore: viewModel.hasMore,
            onLoadMore: viewModel.loadMore,
            itemBuilder: (context, asset) => AdaptiveMaxWidth(
              width: AppContentWidth.detail,
              child: Padding(
                padding: EdgeInsetsDirectional.only(bottom: spacing.sm),
                child: _AssetCard(
                  asset: asset,
                  onTap: () => widget.onOpenAsset(asset),
                ),
              ),
            ),
            emptyBuilder: (context) => QueryEmptyState(
              icon: Icons.devices_other_outlined,
              search: viewModel.searchQuery,
              hasFilters: viewModel.hasActiveFilters,
              emptyTitle: viewModel.inShopOnly
                  ? l10n.assetsInShopEmptyTitle
                  : l10n.assetsEmptyTitle,
              emptyMessage: viewModel.inShopOnly
                  ? l10n.assetsInShopEmptyMessage
                  : l10n.assetsEmptyMessage,
              onClear: viewModel.clearFilters,
            ),
          ),
        ),
      ],
    );
  }
}

class _SearchAndFilters extends StatelessWidget {
  const _SearchAndFilters({required this.viewModel});

  final AssetsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DebouncedSearchField(
          value: viewModel.searchQuery,
          hintText: l10n.assetsSearchHint,
          clearTooltip: l10n.clearSearchTooltip,
          // This screen exists to be typed into; anything else would need a tap
          // first.
          autofocus: true,
          onChanged: (value) => viewModel.searchQuery = value,
        ),
        SizedBox(height: spacing.sm),
        Row(
          children: [
            ChoiceChip(
              label: Text(l10n.assetsAllFilter),
              selected: !viewModel.inShopOnly,
              onSelected: (_) => viewModel.inShopOnly = false,
            ),
            SizedBox(width: spacing.xs),
            ChoiceChip(
              avatar: Icon(
                Icons.home_repair_service_outlined,
                size: 18,
                color: viewModel.inShopOnly
                    ? context.pointyColors.primaryStrong
                    : context.pointyColors.mutedInk,
              ),
              label: Text(l10n.assetsInShopFilter),
              selected: viewModel.inShopOnly,
              onSelected: (_) => viewModel.inShopOnly = true,
            ),
          ],
        ),
      ],
    );
  }
}

class _AssetCard extends StatelessWidget {
  const _AssetCard({required this.asset, required this.onTap});

  final CustomerAsset asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final identity = asset.identityLabel;

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(PointyRadii.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: Ink(
          decoration: BoxDecoration(
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(PointyRadii.card),
          ),
          child: Padding(
            padding: EdgeInsets.all(spacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AssetIconBadge(
                  iconKey: asset.assetTypeIcon,
                  color: asset.isInShop
                      ? colors.primaryStrong
                      : colors.mutedInk,
                ),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              assetTitle(l10n, asset),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (asset.isInShop)
                            PointyStatusPill(
                              label: l10n.assetInShopBadge,
                              icon: Icons.home_repair_service_outlined,
                              color: colors.primaryStrong,
                            ),
                        ],
                      ),
                      if (identity.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Directionality(
                          textDirection: TextDirection.ltr,
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              identity,
                              style: PointyTypography.numeric(
                                textTheme.bodySmall ?? const TextStyle(),
                              ).copyWith(color: colors.mutedInk),
                            ),
                          ),
                        ),
                      ],
                      SizedBox(height: spacing.xs),
                      Wrap(
                        spacing: spacing.sm,
                        runSpacing: spacing.xs / 2,
                        children: [
                          _MetaLine(
                            icon: Icons.person_outline,
                            text: asset.customerName,
                          ),
                          _MetaLine(
                            icon: Icons.history,
                            text: asset.lastJobAt == null
                                ? l10n.assetNeverVisited
                                : formatDate(asset.lastJobAt!),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    final colors = context.pointyColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: colors.mutedInk),
        const SizedBox(width: 4),
        Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
      ],
    );
  }
}
