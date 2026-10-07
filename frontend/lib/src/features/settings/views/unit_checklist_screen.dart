import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/error_messages.dart';
import '../../../data/models/unit_attribute.dart';
import '../../../data/models/unit_checklist_kind.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/tracking/unit_attribute_catalog.dart';
import '../view_models/unit_checklist_view_model.dart';
import 'unit_checklist_field_form.dart';
import 'unit_checklist_field_row.dart';

/// One kind's intake checklist — what is asked about every phone, laptop or
/// car received — in the order the receiving sheet asks it.
///
/// Every successful write drops the app's cached definitions, so the next
/// receiving sheet opened anywhere asks the new list.
class UnitChecklistScreen extends StatefulWidget {
  const UnitChecklistScreen({
    super.key,
    required this.repository,
    required this.kind,
    this.viewModel,
  });

  final TrackedStockRepository repository;
  final UnitChecklistKind kind;

  /// Injected by previews and tests; built from [repository] otherwise.
  final UnitChecklistViewModel? viewModel;

  @override
  State<UnitChecklistScreen> createState() => _UnitChecklistScreenState();
}

class _UnitChecklistScreenState extends State<UnitChecklistScreen> {
  late final UnitChecklistViewModel _viewModel =
      widget.viewModel ??
      UnitChecklistViewModel(repository: widget.repository, kind: widget.kind);

  @override
  void initState() {
    super.initState();
    if (!_viewModel.hasLoaded) {
      unawaited(_viewModel.load());
    }
  }

  @override
  void dispose() {
    if (widget.viewModel == null) {
      _viewModel.dispose();
    }
    super.dispose();
  }

  void _catalogChanged() {
    UnitAttributeCatalogScope.maybeOf(context)?.invalidate();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _edit([UnitAttributeDefinition? field]) async {
    final l10n = AppLocalizations.of(context)!;
    final saved = await showUnitChecklistFieldEditor(
      context,
      assetTypeId: widget.kind.assetTypeId,
      kindName: widget.kind.name,
      initial: field,
      onSave: _viewModel.save,
    );
    if (saved == null || !mounted) return;
    _catalogChanged();
    _snack(l10n.unitChecklistSaved);
  }

  Future<void> _delete(UnitAttributeDefinition field) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => PointyDestructiveConfirmationDialog(
        title: l10n.unitChecklistDeleteTitle(field.label),
        message: l10n.unitChecklistDeleteBody,
        confirmLabel: l10n.deleteButton,
        icon: Icons.delete_outline,
      ),
    );
    if (confirmed != true || !mounted) return;
    final deleted = await _viewModel.delete(field);
    if (!mounted) return;
    if (deleted) {
      _catalogChanged();
      _snack(l10n.unitChecklistDeleted);
    } else {
      _snack(errorMessageFor(_viewModel.actionError!, l10n));
    }
  }

  Future<void> _move(int from, int to) async {
    final l10n = AppLocalizations.of(context)!;
    final moved = await _viewModel.move(from, to);
    if (!mounted) return;
    if (moved) {
      _catalogChanged();
    } else if (_viewModel.actionError != null) {
      _snack(l10n.unitChecklistReorderFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) => PointyScaffold(
        appBar: PointyAppBar(
          title: Text(l10n.unitChecklistScreenTitle(widget.kind.name)),
          isLoading: _viewModel.isLoading || _viewModel.isReordering,
          actions: [
            IconButton(
              tooltip: l10n.retryButton,
              onPressed: _viewModel.isLoading ? null : _viewModel.load,
              icon: const Icon(Icons.sync),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(child: _body(context, l10n)),
            PointyStickyActionFooter(
              primaryAction: FilledButton.icon(
                key: const ValueKey('unit-checklist-add-field'),
                onPressed: _viewModel.hasLoaded ? () => _edit() : null,
                icon: const Icon(Icons.add),
                label: Text(l10n.unitChecklistAddField),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final fields = _viewModel.fields;
    if (!_viewModel.hasLoaded) {
      final error = _viewModel.loadError;
      if (error == null) {
        return const PointyLoadingArea();
      }
      return PointyErrorState(
        title: l10n.unitChecklistLoadError,
        message: errorMessageFor(error, l10n),
        icon: Icons.cloud_off_outlined,
        action: FilledButton.icon(
          onPressed: _viewModel.load,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryButton),
        ),
      );
    }
    final hint = Padding(
      padding: EdgeInsets.only(bottom: spacing.sm),
      child: Text(
        l10n.unitChecklistScreenHint(widget.kind.name),
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
      ),
    );
    if (fields.isEmpty) {
      return PointyEmptyState(
        icon: Icons.fact_check_outlined,
        title: l10n.unitChecklistEmptyTitle,
        message: l10n.unitChecklistEmptyBody,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // Full-width scrolling, form-width content: the list stays under
        // the wheel anywhere on a wide screen.
        final side = math.max(
          spacing.pageHorizontal,
          (constraints.maxWidth - AppMaxContentWidths.form) / 2,
        );
        return ReorderableListView.builder(
          padding: EdgeInsets.symmetric(
            horizontal: side,
            vertical: spacing.pageVertical,
          ),
          header: hint,
          buildDefaultDragHandles: false,
          itemCount: fields.length,
          onReorderItem: _move,
          itemBuilder: (context, index) {
            final field = fields[index];
            return UnitChecklistFieldRow(
              key: ValueKey(field.id),
              index: index,
              field: field,
              isLast: index == fields.length - 1,
              canReorder: !_viewModel.isReordering,
              onEdit: () => _edit(field),
              onDelete: () => _delete(field),
              onMove: (to) => _move(index, to),
            );
          },
        );
      },
    );
  }
}
