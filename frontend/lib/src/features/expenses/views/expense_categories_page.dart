import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/expense_category.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/expense_categories_view_model.dart';

class ExpenseCategoriesPage extends StatefulWidget {
  const ExpenseCategoriesPage({super.key, required this.viewModel});

  final ExpenseCategoriesViewModel viewModel;

  @override
  State<ExpenseCategoriesPage> createState() => _ExpenseCategoriesPageState();
}

class _ExpenseCategoriesPageState extends State<ExpenseCategoriesPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(widget.viewModel.load());
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
          appBar: PointyAppBar(
            title: Text(l10n.expenseCategoriesSectionTitle),
            isLoading: viewModel.isLoading || viewModel.isMutating,
            actions: [
              IconButton(
                tooltip: l10n.expenseCategoryAddButton,
                onPressed: viewModel.isMutating
                    ? null
                    : () => _openEditor(context),
                icon: const Icon(Icons.add),
              ),
              IconButton(
                tooltip: l10n.refreshShopSettingsTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: _buildBody(context, l10n),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && viewModel.categories.isEmpty) {
      return const PointyLoadingArea();
    }

    if (viewModel.hasLoadError && viewModel.categories.isEmpty) {
      return PointyErrorState(
        title: l10n.expenseCategoriesLoadError,
        icon: Icons.sell_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    if (viewModel.categories.isEmpty) {
      return PointyEmptyState(
        icon: Icons.sell_outlined,
        title: l10n.expenseCategoriesEmptyMessage,
        action: FilledButton.icon(
          onPressed: () => _openEditor(context),
          icon: const Icon(Icons.add),
          label: Text(l10n.expenseCategoryAddButton),
        ),
      );
    }

    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: PointySettingsSection(
            children: [
              for (final category in viewModel.categories)
                _ExpenseCategoryTile(
                  category: category,
                  isBusy: viewModel.isMutating,
                  onEdit: () => _openEditor(context, category: category),
                  onDelete: () => _confirmDelete(context, category),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openEditor(
    BuildContext context, {
    ExpenseCategory? category,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final draft = await showDialog<ExpenseCategoryDraft>(
      context: context,
      builder: (_) => _ExpenseCategoryEditorDialog(category: category),
    );
    if (draft == null) {
      return;
    }
    final saved = category == null
        ? await widget.viewModel.createCategory(draft)
        : await widget.viewModel.updateCategory(category.id, draft.toJson());
    if (!saved) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.expenseCategorySaveError)),
      );
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    ExpenseCategory category,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text(l10n.expenseCategoryDeleteTitle),
        content: Text(l10n.expenseCategoryDeleteMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.deleteButton),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    final deleted = await widget.viewModel.deleteCategory(category);
    if (!deleted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.expenseCategoryDeleteError)),
      );
    }
  }
}

class _ExpenseCategoryTile extends StatelessWidget {
  const _ExpenseCategoryTile({
    required this.category,
    required this.isBusy,
    required this.onEdit,
    required this.onDelete,
  });

  final ExpenseCategory category;
  final bool isBusy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    return ListTile(
      leading: const Icon(Icons.sell_outlined),
      title: Row(
        children: [
          Flexible(child: Text(category.name)),
          if (!category.isActive) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: colors.amberContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                l10n.expenseCategoryInactiveBadge,
                style: theme.textTheme.labelSmall?.copyWith(color: colors.ink),
              ),
            ),
          ],
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l10n.editButton,
            onPressed: isBusy ? null : onEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: l10n.deleteButton,
            onPressed: isBusy ? null : onDelete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      onTap: isBusy ? null : onEdit,
    );
  }
}

class _ExpenseCategoryEditorDialog extends StatefulWidget {
  const _ExpenseCategoryEditorDialog({required this.category});

  final ExpenseCategory? category;

  @override
  State<_ExpenseCategoryEditorDialog> createState() =>
      _ExpenseCategoryEditorDialogState();
}

class _ExpenseCategoryEditorDialogState
    extends State<_ExpenseCategoryEditorDialog> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.category?.name ?? '',
  );
  late bool _isActive = widget.category?.isActive ?? true;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _isValid => _nameController.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      icon: const Icon(Icons.sell_outlined),
      title: Text(
        widget.category == null
            ? l10n.expenseCategoryAddButton
            : widget.category!.name,
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.expenseCategoryNameLabel,
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.expenseCategoryActiveLabel),
              value: _isActive,
              onChanged: (value) => setState(() => _isActive = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: _isValid ? _submit : null,
          child: Text(l10n.saveButton),
        ),
      ],
    );
  }

  void _submit() {
    Navigator.of(context).pop(
      ExpenseCategoryDraft(
        name: _nameController.text.trim(),
        isActive: _isActive,
        displayOrder: widget.category?.displayOrder ?? 0,
      ),
    );
  }
}
