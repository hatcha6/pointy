import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/models/product_category.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/product_category_picker.dart';
import '../view_models/category_management_view_model.dart';

class CategoryManagementScreen extends StatelessWidget {
  const CategoryManagementScreen({
    super.key,
    required this.viewModel,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenCatalog,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDashboard,
    this.onOpenDiscounts,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final CategoryManagementViewModel viewModel;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDashboard;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenUsers;
  final VoidCallback? onOpenShopSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return Scaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.categories,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenDashboard: onOpenDashboard,
            onOpenPos: onOpenPos,
            onOpenPurchasing: onOpenPurchasing,
            onOpenContacts: onOpenContacts,
            onOpenCatalog: onOpenCatalog,
            onOpenCategories: () {},
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenDeviceSettings: onOpenDeviceSettings,
            onOpenDiscounts: onOpenDiscounts,
            onOpenUsers: onOpenUsers,
            onOpenShopSettings: onOpenShopSettings,
            onLogout: onLogout,
          ),
          appBar: AppBar(
            leading: Builder(
              builder: (context) {
                return IconButton(
                  tooltip: l10n.navigationMenuTooltip,
                  icon: const Icon(Icons.menu),
                  onPressed: Scaffold.of(context).openDrawer,
                );
              },
            ),
            title: Text(l10n.categoryManagementTitle),
            actions: [
              IconButton(
                tooltip: l10n.refreshCatalogTooltip,
                onPressed: viewModel.loadCategories,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: viewModel.isSaving
                ? null
                : () => _showCategoryForm(context),
            icon: const Icon(Icons.add),
            label: Text(l10n.addCategoryButton),
          ),
          body: SafeArea(child: _CategoryList(viewModel: viewModel)),
        );
      },
    );
  }

  Future<void> _showCategoryForm(BuildContext context) {
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
            onCreated: () => Navigator.of(sheetContext).pop(),
          ),
        );
      },
    );
  }
}

class _CategoryList extends StatelessWidget {
  const _CategoryList({required this.viewModel});

  final CategoryManagementViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (viewModel.isLoading && viewModel.categories.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (viewModel.errorMessage == 'category_load_error' &&
        viewModel.categories.isEmpty) {
      return Center(child: Text(l10n.categoryLoadError));
    }
    return InfiniteScrollList<CategoryTreeItem>(
      items: viewModel.visibleItems,
      onLoadMore: viewModel.loadMoreCategories,
      hasMore: viewModel.hasMoreCategories,
      isLoadingInitial: viewModel.isLoading,
      isLoadingMore: viewModel.isLoadingMore,
      emptyBuilder: (context) => Center(child: Text(l10n.categoryEmptyState)),
      padding: const EdgeInsets.all(16),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, item) {
        return switch (item.type) {
          CategoryTreeItemType.category => _CategoryTreeCategoryTile(
            category: item.category!,
            depth: item.depth,
            isExpanded: viewModel.isExpanded(item.category!),
            isLoadingChildren: viewModel.isLoadingChildren(item.category!),
            onToggleExpanded: () => viewModel.toggleExpanded(item.category!),
          ),
          CategoryTreeItemType.childrenLoading => _CategoryTreeStatusRow(
            depth: item.depth,
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(l10n.categoryLoadingChildren),
              ],
            ),
          ),
          CategoryTreeItemType.childrenLoadError => _CategoryTreeStatusRow(
            depth: item.depth,
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  l10n.categoryChildrenLoadError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                TextButton.icon(
                  onPressed: () => viewModel.retryLoadChildren(item.parent!.id),
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.categoryRetryChildrenButton),
                ),
              ],
            ),
          ),
          CategoryTreeItemType.loadMoreChildren => _CategoryTreeStatusRow(
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

class _CategoryTreeCategoryTile extends StatelessWidget {
  const _CategoryTreeCategoryTile({
    required this.category,
    required this.depth,
    required this.isExpanded,
    required this.isLoadingChildren,
    required this.onToggleExpanded,
  });

  final ProductCategory category;
  final int depth;
  final bool isExpanded;
  final bool isLoadingChildren;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasChildren = category.childrenCount > 0;
    final iconColor = Theme.of(context).colorScheme.primary;

    return ListTile(
      contentPadding: EdgeInsetsDirectional.only(
        start: 16 + depth * 24,
        end: 16,
      ),
      leading: hasChildren
          ? IconButton(
              tooltip: isExpanded
                  ? l10n.categoryCollapseTooltip
                  : l10n.categoryExpandTooltip,
              onPressed: isLoadingChildren ? null : onToggleExpanded,
              icon: Icon(isExpanded ? Icons.expand_more : Icons.chevron_left),
            )
          : Icon(Icons.category_outlined, color: iconColor),
      title: Text(category.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        category.parentName.isEmpty
            ? l10n.rootCategoryLabel
            : l10n.categoryParentValue(category.parentName),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: hasChildren
          ? Chip(
              label: Text(l10n.categoryChildrenCount(category.childrenCount)),
            )
          : null,
    );
  }
}

class _CategoryTreeStatusRow extends StatelessWidget {
  const _CategoryTreeStatusRow({required this.depth, required this.child});

  final int depth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: 64 + depth * 24,
        end: 16,
        top: 8,
        bottom: 8,
      ),
      child: child,
    );
  }
}

class CategoryForm extends StatefulWidget {
  const CategoryForm({
    super.key,
    required this.viewModel,
    required this.onCreated,
  });

  final CategoryManagementViewModel viewModel;
  final VoidCallback onCreated;

  @override
  State<CategoryForm> createState() => _CategoryFormState();
}

class _CategoryFormState extends State<CategoryForm> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  List<AsyncSelectionOption<int>> _selectedParent = [];
  bool _isActive = true;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: ListView(
              shrinkWrap: true,
              children: [
                Text(
                  l10n.newCategoryTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _nameController,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l10n.categoryNameLabel,
                    prefixIcon: const Icon(Icons.category_outlined),
                  ),
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descriptionController,
                  minLines: 2,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: l10n.descriptionLabel,
                    prefixIcon: const Icon(Icons.notes_outlined),
                  ),
                ),
                const SizedBox(height: 12),
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
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.activeCategoryLabel),
                  value: _isActive,
                  onChanged: (value) => setState(() => _isActive = value),
                ),
                if (widget.viewModel.errorMessage ==
                    'category_create_error') ...[
                  const SizedBox(height: 8),
                  Text(
                    l10n.categoryCreateError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: widget.viewModel.isSaving ? null : _submit,
                  icon: widget.viewModel.isSaving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add),
                  label: Text(
                    widget.viewModel.isSaving
                        ? l10n.creatingCategoryButton
                        : l10n.createCategoryButton,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
    final created = await widget.viewModel.createCategory(
      ProductCategoryDraft(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        parentId: _selectedParent.isEmpty ? null : _selectedParent.first.id,
        isActive: _isActive,
      ),
    );
    if (!mounted || !created) {
      return;
    }
    widget.onCreated();
  }
}
