import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_category.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/product_category_picker.dart';
import '../../../shared/query_controls/debounced_search_field.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/category_management_view_model.dart';

/// Manage product categories: a pinned **quick-access** panel that mirrors the
/// POS/purchasing filter strip, a search, and a hierarchical tree with inline
/// pin / edit / add-subcategory / delete actions.
class CategoryManagementScreen extends StatelessWidget {
  const CategoryManagementScreen({
    super.key,
    required this.viewModel,
    required this.navigation,
  });

  final CategoryManagementViewModel viewModel;
  final AppNavigation navigation;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.categories,
            navigation: navigation,
          ),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.categoryManagementTitle),
            actions: [
              IconButton(
                tooltip: l10n.refreshCatalogTooltip,
                onPressed: viewModel.refreshAll,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: viewModel.isSaving
                ? null
                : () => _createCategory(context),
            icon: const Icon(Icons.add),
            label: Text(l10n.addCategoryButton),
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 940),
                child: _CategoryManagementBody(
                  viewModel: viewModel,
                  onCreate: () => _createCategory(context),
                  onCreateChild: (parent) =>
                      _createCategory(context, parent: parent),
                  onEdit: (category) => _editCategory(context, category),
                  onToggleQuickAccess: (category) =>
                      _toggleQuickAccess(context, category),
                  onReorderQuickAccess: (oldIndex, newIndex) =>
                      _reorderQuickAccess(context, oldIndex, newIndex),
                  onDelete: (category) => _deleteCategory(context, category),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _createCategory(
    BuildContext context, {
    ProductCategory? parent,
  }) {
    return _showCategoryForm(context, initialParent: parent);
  }

  Future<void> _editCategory(BuildContext context, ProductCategory category) {
    return _showCategoryForm(context, category: category);
  }

  Future<void> _showCategoryForm(
    BuildContext context, {
    ProductCategory? category,
    ProductCategory? initialParent,
  }) {
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
          child: CategoryForm(
            viewModel: viewModel,
            category: category,
            initialParent: initialParent,
            onSaved: () => Navigator.of(sheetContext).pop(),
          ),
        );
      },
    );
  }

  Future<void> _toggleQuickAccess(
    BuildContext context,
    ProductCategory category,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final wasPinned = category.isQuickAccess;
    final ok = await viewModel.toggleQuickAccess(category);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            !ok
                ? l10n.quickAccessUpdateError
                : wasPinned
                ? l10n.quickAccessRemovedMessage(category.name)
                : l10n.quickAccessAddedMessage(category.name),
          ),
        ),
      );
  }

  Future<void> _reorderQuickAccess(
    BuildContext context,
    int oldIndex,
    int newIndex,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await viewModel.reorderQuickAccess(oldIndex, newIndex);
    if (!ok) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.quickAccessUpdateError)));
    }
  }

  Future<void> _deleteCategory(
    BuildContext context,
    ProductCategory category,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);

    if (category.childrenCount > 0) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.account_tree_outlined),
          title: Text(l10n.deleteCategoryHasChildrenTitle),
          content: Text(l10n.deleteCategoryHasChildrenMessage),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.confirmButton),
            ),
          ],
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => PointyDestructiveConfirmationDialog(
        title: l10n.deleteCategoryTitle,
        message: l10n.deleteCategoryConfirmMessage(category.name),
        confirmLabel: l10n.deleteButton,
      ),
    );
    if (confirmed != true) {
      return;
    }

    final ok = await viewModel.deleteCategory(category);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ok ? l10n.categoryDeletedMessage : l10n.categoryDeleteError,
          ),
        ),
      );
  }
}

class _CategoryManagementBody extends StatelessWidget {
  const _CategoryManagementBody({
    required this.viewModel,
    required this.onCreate,
    required this.onCreateChild,
    required this.onEdit,
    required this.onToggleQuickAccess,
    required this.onReorderQuickAccess,
    required this.onDelete,
  });

  final CategoryManagementViewModel viewModel;
  final VoidCallback onCreate;
  final ValueChanged<ProductCategory> onCreateChild;
  final ValueChanged<ProductCategory> onEdit;
  final ValueChanged<ProductCategory> onToggleQuickAccess;
  final void Function(int oldIndex, int newIndex) onReorderQuickAccess;
  final ValueChanged<ProductCategory> onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            spacing.lg,
            spacing.md,
            spacing.lg,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _QuickAccessPanel(
                viewModel: viewModel,
                onToggleQuickAccess: onToggleQuickAccess,
                onReorder: onReorderQuickAccess,
                onBrowse: onCreate,
              ),
              SizedBox(height: spacing.md),
              DebouncedSearchField(
                value: viewModel.search,
                hintText: l10n.categorySearchHint,
                clearTooltip: l10n.clearButton,
                fieldKey: const ValueKey('category_search_field'),
                onChanged: viewModel.applySearch,
              ),
              SizedBox(height: spacing.sm),
              PointySectionHeader(
                title: viewModel.isSearching
                    ? l10n.categorySearchResultsTitle
                    : l10n.allCategoriesSectionTitle,
                padding: EdgeInsetsDirectional.only(
                  top: spacing.xs,
                  bottom: spacing.xs,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: viewModel.isSearching
              ? _SearchResultsList(
                  viewModel: viewModel,
                  onEdit: onEdit,
                  onCreateChild: onCreateChild,
                  onToggleQuickAccess: onToggleQuickAccess,
                  onDelete: onDelete,
                )
              : _CategoryTreeList(
                  viewModel: viewModel,
                  onEdit: onEdit,
                  onCreateChild: onCreateChild,
                  onToggleQuickAccess: onToggleQuickAccess,
                  onDelete: onDelete,
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Quick-access panel
// ---------------------------------------------------------------------------

class _QuickAccessPanel extends StatelessWidget {
  const _QuickAccessPanel({
    required this.viewModel,
    required this.onToggleQuickAccess,
    required this.onReorder,
    required this.onBrowse,
  });

  final CategoryManagementViewModel viewModel;
  final ValueChanged<ProductCategory> onToggleQuickAccess;
  final void Function(int oldIndex, int newIndex) onReorder;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
        boxShadow: PointyShadows.raised,
      ),
      padding: EdgeInsetsDirectional.all(spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.push_pin_outlined,
                color: colors.primaryStrong,
                size: 20,
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.quickAccessSectionTitle,
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.quickAccessSectionSubtitle,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                  ],
                ),
              ),
              if (viewModel.hasQuickAccess)
                Padding(
                  padding: EdgeInsetsDirectional.only(start: spacing.sm),
                  child: PointyStatusPill(
                    label: '${viewModel.quickAccess.length}',
                    icon: Icons.bolt_outlined,
                  ),
                ),
            ],
          ),
          SizedBox(height: spacing.md),
          _QuickAccessContent(
            viewModel: viewModel,
            onToggleQuickAccess: onToggleQuickAccess,
            onReorder: onReorder,
          ),
        ],
      ),
    );
  }
}

class _QuickAccessContent extends StatelessWidget {
  const _QuickAccessContent({
    required this.viewModel,
    required this.onToggleQuickAccess,
    required this.onReorder,
  });

  final CategoryManagementViewModel viewModel;
  final ValueChanged<ProductCategory> onToggleQuickAccess;
  final void Function(int oldIndex, int newIndex) onReorder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    if (viewModel.quickAccessError && !viewModel.hasQuickAccess) {
      return Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: colors.danger),
          SizedBox(width: spacing.sm),
          Expanded(child: Text(l10n.quickAccessLoadError)),
          TextButton(
            onPressed: viewModel.loadQuickAccess,
            child: Text(l10n.retryButton),
          ),
        ],
      );
    }

    if (!viewModel.hasQuickAccess) {
      if (viewModel.isLoadingQuickAccess) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: SizedBox.square(
              dimension: 20,
              child: PointySpinner(strokeWidth: 2),
            ),
          ),
        );
      }
      return DecoratedBox(
        decoration: BoxDecoration(
          color: colors.subtleFill,
          borderRadius: BorderRadius.circular(PointyRadii.chip),
          border: Border.all(color: colors.line),
        ),
        child: Padding(
          padding: EdgeInsetsDirectional.all(spacing.md),
          child: Row(
            children: [
              Icon(Icons.push_pin_outlined, color: colors.mutedInk, size: 22),
              SizedBox(width: spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.quickAccessEmptyTitle,
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.quickAccessEmptyMessage,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final categories = viewModel.quickAccess;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 46,
          child: ReorderableListView.builder(
            scrollDirection: Axis.horizontal,
            buildDefaultDragHandles: false,
            padding: EdgeInsets.zero,
            proxyDecorator: (child, index, animation) =>
                Material(color: Colors.transparent, child: child),
            itemCount: categories.length,
            onReorder: onReorder,
            itemBuilder: (context, index) {
              final category = categories[index];
              return ReorderableDragStartListener(
                key: ValueKey('quick_access_${category.id}'),
                index: index,
                child: Padding(
                  padding: EdgeInsetsDirectional.only(end: spacing.sm),
                  child: _QuickAccessChip(
                    category: category,
                    onRemove: () => onToggleQuickAccess(category),
                  ),
                ),
              );
            },
          ),
        ),
        SizedBox(height: spacing.sm),
        Row(
          children: [
            Icon(Icons.drag_indicator, size: 16, color: colors.mutedInk),
            const SizedBox(width: 4),
            Text(
              l10n.quickAccessReorderHint,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ],
        ),
      ],
    );
  }
}

class _QuickAccessChip extends StatelessWidget {
  const _QuickAccessChip({required this.category, required this.onRemove});

  final ProductCategory category;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        border: Border.all(color: colors.primaryStrong.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 10, end: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.drag_indicator, size: 16, color: colors.primaryStrong),
            const SizedBox(width: 4),
            Text(
              category.name,
              style: textTheme.labelLarge?.copyWith(
                color: colors.primaryDark,
                fontWeight: FontWeight.w700,
              ),
            ),
            IconButton(
              onPressed: onRemove,
              tooltip: l10n.unpinFromQuickAccessTooltip,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              icon: Icon(Icons.close, size: 16, color: colors.primaryStrong),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tree + search lists
// ---------------------------------------------------------------------------

class _CategoryTreeList extends StatelessWidget {
  const _CategoryTreeList({
    required this.viewModel,
    required this.onEdit,
    required this.onCreateChild,
    required this.onToggleQuickAccess,
    required this.onDelete,
  });

  final CategoryManagementViewModel viewModel;
  final ValueChanged<ProductCategory> onEdit;
  final ValueChanged<ProductCategory> onCreateChild;
  final ValueChanged<ProductCategory> onToggleQuickAccess;
  final ValueChanged<ProductCategory> onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && viewModel.categories.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && viewModel.categories.isEmpty) {
      return PointyErrorState(
        title: l10n.categoriesLoadError,
        action: OutlinedButton.icon(
          onPressed: viewModel.loadCategories,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryButton),
        ),
      );
    }

    return InfiniteScrollList<CategoryTreeItem>(
      items: viewModel.visibleItems,
      onLoadMore: viewModel.loadMoreCategories,
      hasMore: viewModel.hasMoreCategories,
      isLoadingInitial: viewModel.isLoading,
      isLoadingMore: viewModel.isLoadingMore,
      emptyBuilder: (context) => PointyEmptyState(
        icon: Icons.category_outlined,
        title: l10n.categoryEmptyState,
        message: l10n.categoryEmptyHint,
      ),
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.lg,
        spacing.xs,
        spacing.lg,
        spacing.xxl,
      ),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, item) {
        return switch (item.type) {
          CategoryTreeItemType.category => _CategoryRow(
            category: item.category!,
            depth: item.depth,
            hasExpander: item.category!.childrenCount > 0,
            isExpanded: viewModel.isExpanded(item.category!),
            isLoadingChildren: viewModel.isLoadingChildren(item.category!),
            onToggleExpanded: () => viewModel.toggleExpanded(item.category!),
            onEdit: () => onEdit(item.category!),
            onCreateChild: () => onCreateChild(item.category!),
            onToggleQuickAccess: () => onToggleQuickAccess(item.category!),
            onDelete: () => onDelete(item.category!),
          ),
          CategoryTreeItemType.childrenLoading => _TreeStatusRow(
            depth: item.depth,
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 18,
                  child: PointySpinner(strokeWidth: 2),
                ),
                SizedBox(width: spacing.sm),
                Text(l10n.categoryLoadingChildren),
              ],
            ),
          ),
          CategoryTreeItemType.childrenLoadError => _TreeStatusRow(
            depth: item.depth,
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  l10n.categoryChildrenLoadError,
                  style: TextStyle(color: context.pointyColors.danger),
                ),
                TextButton.icon(
                  onPressed: () => viewModel.retryLoadChildren(item.parent!.id),
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.retryButton),
                ),
              ],
            ),
          ),
          CategoryTreeItemType.loadMoreChildren => _TreeStatusRow(
            depth: item.depth,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => viewModel.loadMoreChildren(item.parent!.id),
                icon: const Icon(Icons.expand_more),
                label: Text(l10n.categoryLoadMoreChildrenButton),
              ),
            ),
          ),
        };
      },
    );
  }
}

class _SearchResultsList extends StatelessWidget {
  const _SearchResultsList({
    required this.viewModel,
    required this.onEdit,
    required this.onCreateChild,
    required this.onToggleQuickAccess,
    required this.onDelete,
  });

  final CategoryManagementViewModel viewModel;
  final ValueChanged<ProductCategory> onEdit;
  final ValueChanged<ProductCategory> onCreateChild;
  final ValueChanged<ProductCategory> onToggleQuickAccess;
  final ValueChanged<ProductCategory> onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoadingSearch && viewModel.searchResults.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasSearchError && viewModel.searchResults.isEmpty) {
      return PointyErrorState(
        title: l10n.categoriesLoadError,
        action: OutlinedButton.icon(
          onPressed: viewModel.retrySearch,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryButton),
        ),
      );
    }

    return InfiniteScrollList<ProductCategory>(
      items: viewModel.searchResults,
      onLoadMore: viewModel.loadMoreSearchResults,
      hasMore: viewModel.hasMoreSearch,
      isLoadingInitial: viewModel.isLoadingSearch,
      isLoadingMore: viewModel.isLoadingMoreSearch,
      emptyBuilder: (context) => PointyEmptyState(
        icon: Icons.search_off_outlined,
        title: l10n.categorySearchEmptyState,
      ),
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.lg,
        spacing.xs,
        spacing.lg,
        spacing.xxl,
      ),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, category) {
        return _CategoryRow(
          category: category,
          depth: 0,
          hasExpander: false,
          isExpanded: false,
          isLoadingChildren: false,
          showPath: true,
          onToggleExpanded: () {},
          onEdit: () => onEdit(category),
          onCreateChild: () => onCreateChild(category),
          onToggleQuickAccess: () => onToggleQuickAccess(category),
          onDelete: () => onDelete(category),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Category row
// ---------------------------------------------------------------------------

enum _CategoryRowAction { edit, addChild, delete }

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.depth,
    required this.hasExpander,
    required this.isExpanded,
    required this.isLoadingChildren,
    required this.onToggleExpanded,
    required this.onEdit,
    required this.onCreateChild,
    required this.onToggleQuickAccess,
    required this.onDelete,
    this.showPath = false,
  });

  final ProductCategory category;
  final int depth;
  final bool hasExpander;
  final bool isExpanded;
  final bool isLoadingChildren;
  final bool showPath;
  final VoidCallback onToggleExpanded;
  final VoidCallback onEdit;
  final VoidCallback onCreateChild;
  final VoidCallback onToggleQuickAccess;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final pinned = category.isQuickAccess;

    final subtitleParts = <String>[
      if (showPath && !category.isRoot)
        l10n.categoryParentValue(category.parentName)
      else if (showPath)
        l10n.rootCategoryLabel,
      l10n.categoryProductCount(category.productCount),
      if (category.childrenCount > 0)
        l10n.categoryChildrenCount(category.childrenCount),
    ];

    return InkWell(
      onTap: hasExpander ? onToggleExpanded : onEdit,
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: 12 + depth * 20,
          end: 4,
          top: 8,
          bottom: 8,
        ),
        child: Row(
          children: [
            _RowLeading(
              hasExpander: hasExpander,
              isExpanded: isExpanded,
              isLoadingChildren: isLoadingChildren,
              onToggleExpanded: onToggleExpanded,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          category.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: category.isActive
                                ? colors.ink
                                : colors.mutedInk,
                          ),
                        ),
                      ),
                      if (!category.isActive) ...[
                        const SizedBox(width: 6),
                        PointyStatusPill(
                          label: l10n.categoryInactiveBadge,
                          color: colors.mutedInk,
                        ),
                      ],
                    ],
                  ),
                  if (subtitleParts.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitleParts.join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              onPressed: onToggleQuickAccess,
              tooltip: pinned
                  ? l10n.unpinFromQuickAccessTooltip
                  : l10n.pinToQuickAccessTooltip,
              icon: Icon(
                pinned ? Icons.push_pin : Icons.push_pin_outlined,
                color: pinned ? colors.primaryStrong : colors.mutedInk,
              ),
            ),
            PopupMenuButton<_CategoryRowAction>(
              tooltip: l10n.categoryActionsTooltip,
              icon: Icon(Icons.more_vert, color: colors.mutedInk),
              onSelected: (action) {
                switch (action) {
                  case _CategoryRowAction.edit:
                    onEdit();
                  case _CategoryRowAction.addChild:
                    onCreateChild();
                  case _CategoryRowAction.delete:
                    onDelete();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _CategoryRowAction.edit,
                  child: _MenuRow(
                    icon: Icons.edit_outlined,
                    label: l10n.editButton,
                  ),
                ),
                PopupMenuItem(
                  value: _CategoryRowAction.addChild,
                  child: _MenuRow(
                    icon: Icons.subdirectory_arrow_left_outlined,
                    label: l10n.addSubcategoryAction,
                  ),
                ),
                PopupMenuItem(
                  value: _CategoryRowAction.delete,
                  child: _MenuRow(
                    icon: Icons.delete_outline,
                    label: l10n.deleteButton,
                    danger: true,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RowLeading extends StatelessWidget {
  const _RowLeading({
    required this.hasExpander,
    required this.isExpanded,
    required this.isLoadingChildren,
    required this.onToggleExpanded,
  });

  final bool hasExpander;
  final bool isExpanded;
  final bool isLoadingChildren;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    if (!hasExpander) {
      return Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.subtleFill,
          borderRadius: BorderRadius.circular(PointyRadii.chip),
        ),
        child: Icon(Icons.sell_outlined, size: 18, color: colors.mutedInk),
      );
    }

    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        padding: EdgeInsets.zero,
        tooltip: isExpanded
            ? l10n.categoryCollapseTooltip
            : l10n.categoryExpandTooltip,
        onPressed: isLoadingChildren ? null : onToggleExpanded,
        icon: isLoadingChildren
            ? const SizedBox.square(
                dimension: 18,
                child: PointySpinner(strokeWidth: 2),
              )
            : Icon(
                isExpanded ? Icons.expand_more : Icons.chevron_right,
                color: colors.primaryStrong,
              ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final color = danger ? colors.danger : colors.ink;
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

class _TreeStatusRow extends StatelessWidget {
  const _TreeStatusRow({required this.depth, required this.child});

  final int depth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: 56 + depth * 20,
        end: 16,
        top: 8,
        bottom: 8,
      ),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Create / edit form
// ---------------------------------------------------------------------------

class CategoryForm extends StatefulWidget {
  const CategoryForm({
    super.key,
    required this.viewModel,
    required this.onSaved,
    this.category,
    this.initialParent,
  });

  final CategoryManagementViewModel viewModel;
  final VoidCallback onSaved;

  /// When set, the form edits this category; otherwise it creates a new one.
  final ProductCategory? category;

  /// Preselected parent when creating a subcategory.
  final ProductCategory? initialParent;

  @override
  State<CategoryForm> createState() => _CategoryFormState();
}

class _CategoryFormState extends State<CategoryForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  List<AsyncSelectionOption<int>> _selectedParent = [];
  late bool _isActive;
  late bool _isQuickAccess;
  bool _submitFailed = false;

  bool get _isEditing => widget.category != null;

  @override
  void initState() {
    super.initState();
    final category = widget.category;
    _nameController = TextEditingController(text: category?.name ?? '');
    _descriptionController = TextEditingController(
      text: category?.description ?? '',
    );
    _isActive = category?.isActive ?? true;
    _isQuickAccess = category?.isQuickAccess ?? false;

    final parentId = category?.parentId ?? widget.initialParent?.id;
    final parentName = category != null
        ? category.parentName
        : widget.initialParent?.name ?? '';
    if (parentId != null) {
      _selectedParent = [
        AsyncSelectionOption<int>(
          id: parentId,
          label: parentName,
          subtitle: '',
        ),
      ];
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final saving = widget.viewModel.isSaving;

    return Align(
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: EdgeInsets.all(spacing.lg),
          child: Form(
            key: _formKey,
            child: ListView(
              shrinkWrap: true,
              children: [
                Text(
                  _isEditing ? l10n.editCategoryTitle : l10n.newCategoryTitle,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                SizedBox(height: spacing.lg),
                TextFormField(
                  controller: _nameController,
                  autofocus: !_isEditing,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l10n.categoryNameLabel,
                    prefixIcon: const Icon(Icons.category_outlined),
                  ),
                  validator: _requiredValidator,
                ),
                SizedBox(height: spacing.md),
                TextFormField(
                  controller: _descriptionController,
                  minLines: 2,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: l10n.descriptionLabel,
                    prefixIcon: const Icon(Icons.notes_outlined),
                  ),
                ),
                SizedBox(height: spacing.md),
                AsyncSelectionField<int>(
                  fieldKey: const ValueKey('category_parent_field'),
                  strings: AsyncSelectionFieldStrings<int>(
                    label: l10n.parentCategoryLabel,
                    emptyText: l10n.noParentCategory,
                    helperText: l10n.parentCategoryHelper,
                    clearTooltip: l10n.clearButton,
                    openPickerTooltip: l10n.productCategoriesOpenPickerTooltip,
                    fallbackLabelForId: l10n.productCategoryFallbackLabel,
                  ),
                  selected: _selectedParent,
                  onPick: _pickParent,
                  onClear: _selectedParent.isEmpty
                      ? null
                      : () => setState(() => _selectedParent = []),
                  validator: (_) => null,
                ),
                SizedBox(height: spacing.sm),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.activeCategoryLabel),
                  value: _isActive,
                  onChanged: (value) => setState(() => _isActive = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: Icon(
                    Icons.push_pin_outlined,
                    color: colors.primaryStrong,
                  ),
                  title: Text(l10n.quickAccessSwitchLabel),
                  subtitle: Text(l10n.quickAccessSwitchHelper),
                  value: _isQuickAccess,
                  onChanged: (value) => setState(() => _isQuickAccess = value),
                ),
                if (_submitFailed) ...[
                  SizedBox(height: spacing.sm),
                  Text(
                    _isEditing
                        ? l10n.categoryUpdateError
                        : l10n.categoryCreateError,
                    style: TextStyle(color: colors.danger),
                  ),
                ],
                SizedBox(height: spacing.lg),
                FilledButton.icon(
                  onPressed: saving ? null : _submit,
                  icon: saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: PointySpinner(strokeWidth: 2),
                        )
                      : Icon(_isEditing ? Icons.check : Icons.add),
                  label: Text(_submitLabel(l10n, saving)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _submitLabel(AppLocalizations l10n, bool saving) {
    if (_isEditing) {
      return saving ? l10n.savingCategoryButton : l10n.saveButton;
    }
    return saving ? l10n.creatingCategoryButton : l10n.createCategoryButton;
  }

  String? _requiredValidator(String? value) {
    if (value == null || value.trim().isEmpty) {
      return AppLocalizations.of(context)!.requiredField;
    }
    return null;
  }

  Future<void> _pickParent() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: productCategoryPickerStrings(l10n),
      selected: _selectedParent,
      searchFieldKey: const ValueKey('category_parent_search_field'),
      applyButtonKey: const ValueKey('category_parent_apply_button'),
      optionKeyForId: (id) => ValueKey('category_parent_option_$id'),
      loadPage: (search, page) => loadProductCategorySelectionPage(
        catalogRepository: widget.viewModel.catalogRepository,
        search: search,
        page: page,
      ),
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _selectedParent = picked.take(1).toList(growable: false));
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _submitFailed = false);

    final draft = ProductCategoryDraft(
      name: _nameController.text.trim(),
      description: _descriptionController.text.trim(),
      parentId: _selectedParent.isEmpty ? null : _selectedParent.first.id,
      isActive: _isActive,
      isQuickAccess: _isQuickAccess,
    );

    final category = widget.category;
    final saved = category == null
        ? await widget.viewModel.createCategory(draft)
        : await widget.viewModel.updateCategory(category, draft);
    if (!mounted) {
      return;
    }
    if (saved) {
      widget.onSaved();
    } else {
      setState(() => _submitFailed = true);
    }
  }
}
