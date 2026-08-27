import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/bill_of_materials.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/recipes_view_model.dart';
import 'jobs_screen.dart' show formatQuantity, unitLabel;
import 'variant_picker_sheet.dart';
import '../../../core/authorization.dart';

class RecipesPage extends StatefulWidget {
  const RecipesPage({
    super.key,
    required this.viewModel,
    required this.catalogRepository,
    required this.capabilities,
  });

  final RecipesViewModel viewModel;
  final CatalogRepository catalogRepository;
  final AuthorizationCapabilities capabilities;

  @override
  State<RecipesPage> createState() => _RecipesPageState();
}

class _RecipesPageState extends State<RecipesPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Gate the call on the permission, not the response: this list used to
      // fire boms/ and take a 403 for a cashier who can open the operations
      // board but not read recipes.
      if (mounted && widget.capabilities.canViewRecipes) {
        unawaited(widget.viewModel.loadRecipes());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final spacing = AdaptiveSpacing.of(context);
        final viewModel = widget.viewModel;

        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.recipesTitle),
            isLoading: viewModel.isLoading || viewModel.isMutating,
            actions: [
              IconButton(
                tooltip: l10n.newRecipeButton,
                onPressed: viewModel.isMutating
                    ? null
                    : () => _openEditor(context),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          body: viewModel.isLoading && viewModel.recipes.isEmpty
              ? const PointyLoadingArea()
              : viewModel.hasLoadError && viewModel.recipes.isEmpty
              ? PointyErrorState(
                  title: l10n.recipesLoadError,
                  icon: Icons.menu_book_outlined,
                  action: FilledButton.icon(
                    onPressed: viewModel.loadRecipes,
                    icon: const Icon(Icons.sync),
                    label: Text(l10n.retryButton),
                  ),
                )
              : viewModel.recipes.isEmpty
              ? PointyEmptyState(
                  icon: Icons.menu_book_outlined,
                  title: l10n.recipesTitle,
                  message: l10n.recipesEmptyMessage,
                  action: FilledButton.icon(
                    onPressed: () => _openEditor(context),
                    icon: const Icon(Icons.add),
                    label: Text(l10n.newRecipeButton),
                  ),
                )
              : ListView(
                  padding: spacing.pagePadding,
                  children: [
                    AdaptiveMaxWidth(
                      width: AppContentWidth.form,
                      child: PointySettingsSection(
                        children: [
                          for (final recipe in viewModel.recipes)
                            ListTile(
                              leading: const Icon(Icons.menu_book_outlined),
                              title: Text(recipe.name),
                              subtitle: Text(
                                '${recipe.productName.isEmpty ? recipe.variantName : recipe.productName}'
                                ' · ${l10n.productionOutputPreview('${recipe.outputQuantity}', recipe.variantName.isEmpty ? recipe.productName : recipe.variantName)}',
                              ),
                              trailing: PopupMenuButton<String>(
                                enabled: !viewModel.isMutating,
                                onSelected: (action) {
                                  if (action == 'delete') {
                                    _confirmDelete(context, recipe);
                                  }
                                },
                                itemBuilder: (menuContext) => [
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text(l10n.recipeDeleteAction),
                                  ),
                                ],
                              ),
                              onTap: viewModel.isMutating
                                  ? null
                                  : () => _openEditor(context, recipe: recipe),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Future<void> _openEditor(BuildContext context, {BillOfMaterials? recipe}) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _RecipeEditorPage(
          viewModel: widget.viewModel,
          catalogRepository: widget.catalogRepository,
          recipe: recipe,
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    BillOfMaterials recipe,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => PointyDestructiveConfirmationDialog(
        title: l10n.recipeDeleteConfirmTitle,
        message: l10n.recipeDeleteConfirmMessage(recipe.name),
        confirmLabel: l10n.recipeDeleteAction,
        icon: Icons.delete_outline,
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final deleted = await widget.viewModel.delete(recipe.id);
    if (!deleted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.operationsActionError)),
      );
    }
  }
}

class _EditableLine {
  _EditableLine({
    this.id,
    required this.componentVariant,
    required this.componentLabel,
    this.componentUnit = 'piece',
    this.quantity = 1,
    this.wastePercent = 0,
  });

  final int? id;
  int componentVariant;
  String componentLabel;
  String componentUnit;
  double quantity;
  double wastePercent;
}

class _RecipeEditorPage extends StatefulWidget {
  const _RecipeEditorPage({
    required this.viewModel,
    required this.catalogRepository,
    this.recipe,
  });

  final RecipesViewModel viewModel;
  final CatalogRepository catalogRepository;
  final BillOfMaterials? recipe;

  @override
  State<_RecipeEditorPage> createState() => _RecipeEditorPageState();
}

class _RecipeEditorPageState extends State<_RecipeEditorPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _outputQuantityController;
  int? _outputVariantId;
  String _outputVariantLabel = '';
  late List<_EditableLine> _lines;
  var _showValidation = false;
  var _makeToOrder = true;

  @override
  void initState() {
    super.initState();
    final recipe = widget.recipe;
    _nameController = TextEditingController(text: recipe?.name ?? '');
    _outputQuantityController = TextEditingController(
      text: '${recipe?.outputQuantity ?? 1}',
    );
    _makeToOrder = recipe?.isPrepared ?? true;
    _outputVariantId = recipe?.variant;
    _outputVariantLabel = recipe == null
        ? ''
        : (recipe.variantName.isEmpty
              ? recipe.productName
              : recipe.variantName);
    _lines = [
      for (final line in recipe?.lines ?? const <BomLine>[])
        _EditableLine(
          id: line.id,
          componentVariant: line.componentVariant,
          componentLabel: line.componentName.isEmpty
              ? line.componentProductName
              : line.componentName,
          componentUnit: line.componentUnit,
          quantity: line.quantity,
          wastePercent: line.wastePercent,
        ),
    ];
  }

  @override
  void dispose() {
    _nameController.dispose();
    _outputQuantityController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final isSaving = widget.viewModel.isMutating;
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(
              widget.recipe == null ? l10n.newRecipeButton : l10n.recipesTitle,
            ),
            isLoading: isSaving,
          ),
          body: ListView(
            padding: spacing.pagePadding,
            children: [
              AdaptiveMaxWidth(
                width: AppContentWidth.form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _nameController,
                      enabled: !isSaving,
                      decoration: InputDecoration(
                        labelText: l10n.recipeNameLabel,
                        errorText:
                            _showValidation &&
                                _nameController.text.trim().isEmpty
                            ? l10n.recipeNameRequired
                            : null,
                      ),
                    ),
                    SizedBox(height: spacing.md),
                    ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: context.pointyColors.line),
                      ),
                      leading: const Icon(Icons.inventory_2_outlined),
                      title: Text(l10n.recipeOutputVariantLabel),
                      subtitle: Text(
                        _outputVariantLabel.isEmpty
                            ? l10n.recipeOutputVariantLabel
                            : _outputVariantLabel,
                      ),
                      trailing: const PointyDisclosureChevron(),
                      enabled: !isSaving,
                      onTap: _pickOutputVariant,
                    ),
                    SizedBox(height: spacing.md),
                    TextField(
                      controller: _outputQuantityController,
                      enabled: !isSaving,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: l10n.recipeOutputQuantityLabel,
                      ),
                    ),
                    SizedBox(height: spacing.md),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: context.pointyColors.line),
                      ),
                      secondary: const Icon(Icons.restaurant_outlined),
                      title: Text(l10n.recipeMakeToOrderLabel),
                      subtitle: Text(
                        _makeToOrder
                            ? l10n.recipeMakeToOrderHelper
                            : l10n.recipeProduceToStockHelper,
                      ),
                      value: _makeToOrder,
                      onChanged: isSaving
                          ? null
                          : (value) => setState(() => _makeToOrder = value),
                    ),
                    SizedBox(height: spacing.lg),
                    PointySectionHeader(
                      title: l10n.recipeComponentsTitle,
                      leading: const Icon(Icons.format_list_bulleted),
                    ),
                    if (_showValidation && _lines.isEmpty)
                      PointyInlineMessage.error(
                        message: l10n.recipeComponentsRequired,
                        icon: Icons.warning_amber_outlined,
                      ),
                    SizedBox(height: spacing.sm),
                    for (var index = 0; index < _lines.length; index++)
                      _componentRow(context, index, isSaving),
                    SizedBox(height: spacing.sm),
                    OutlinedButton.icon(
                      onPressed: isSaving ? null : _addComponent,
                      icon: const Icon(Icons.add),
                      label: Text(l10n.recipeAddComponentButton),
                    ),
                    SizedBox(height: spacing.lg),
                    FilledButton.icon(
                      onPressed: isSaving ? null : _save,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(l10n.recipeSaveButton),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _componentRow(BuildContext context, int index, bool isSaving) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final line = _lines[index];

    return Card(
      margin: EdgeInsets.only(bottom: spacing.sm),
      child: Padding(
        padding: EdgeInsets.all(spacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Text(
                line.componentLabel,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(width: spacing.sm),
            SizedBox(
              width: 88,
              child: TextFormField(
                initialValue: formatQuantity(line.quantity),
                enabled: !isSaving,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: l10n.recipeComponentQuantityLabel,
                  suffixText: unitLabel(l10n, line.componentUnit),
                  isDense: true,
                ),
                onChanged: (value) {
                  line.quantity =
                      double.tryParse(value.trim()) ?? line.quantity;
                },
              ),
            ),
            SizedBox(width: spacing.sm),
            SizedBox(
              width: 88,
              child: TextFormField(
                initialValue: line.wastePercent == 0
                    ? '0'
                    : line.wastePercent.toStringAsFixed(0),
                enabled: !isSaving,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: l10n.recipeWastePercentLabel,
                  isDense: true,
                ),
                onChanged: (value) {
                  line.wastePercent =
                      double.tryParse(value.trim()) ?? line.wastePercent;
                },
              ),
            ),
            IconButton(
              onPressed: isSaving
                  ? null
                  : () => setState(() => _lines.removeAt(index)),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickOutputVariant() async {
    final l10n = AppLocalizations.of(context)!;
    final variant = await showVariantPickerSheet(
      context,
      catalogRepository: widget.catalogRepository,
      title: l10n.recipeOutputVariantLabel,
    );
    if (variant == null || !mounted) {
      return;
    }
    setState(() {
      _outputVariantId = variant.id;
      _outputVariantLabel = variant.displayLabel;
    });
  }

  Future<void> _addComponent() async {
    final l10n = AppLocalizations.of(context)!;
    final variant = await showVariantPickerSheet(
      context,
      catalogRepository: widget.catalogRepository,
      title: l10n.recipeAddComponentButton,
    );
    if (variant == null || !mounted) {
      return;
    }
    setState(() {
      _lines.add(
        _EditableLine(
          componentVariant: variant.id,
          componentLabel: variant.displayLabel,
          componentUnit: variant.unit,
        ),
      );
    });
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final name = _nameController.text.trim();
    if (name.isEmpty || _outputVariantId == null || _lines.isEmpty) {
      setState(() => _showValidation = true);
      return;
    }

    final saved = await widget.viewModel.save(
      BillOfMaterialsDraft(
        id: widget.recipe?.id,
        name: name,
        variant: _outputVariantId!,
        outputQuantity:
            int.tryParse(_outputQuantityController.text.trim()) ?? 1,
        makeToOrder: _makeToOrder,
        lines: [
          for (final line in _lines)
            BomLineDraft(
              id: line.id,
              componentVariant: line.componentVariant,
              quantity: line.quantity,
              wastePercent: line.wastePercent,
            ),
        ],
      ),
    );
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved ? l10n.recipeSavedMessage : l10n.operationsActionError,
        ),
      ),
    );
    if (saved) {
      Navigator.of(context).pop();
    }
  }
}
