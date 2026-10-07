import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/error_messages.dart';
import '../../../data/models/unit_checklist_kind.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../assets/views/assets_ui.dart';
import '../view_models/unit_checklist_kinds_view_model.dart';
import 'unit_checklist_screen.dart';

/// «قوائم فحص الأجهزة»: every kind of device the shop takes in, and how long
/// each one's intake checklist is. Tapping a kind edits its list.
class UnitChecklistsScreen extends StatefulWidget {
  const UnitChecklistsScreen({
    super.key,
    required this.repository,
    this.viewModel,
  });

  final TrackedStockRepository repository;

  /// Injected by previews and tests; built from [repository] otherwise.
  final UnitChecklistKindsViewModel? viewModel;

  @override
  State<UnitChecklistsScreen> createState() => _UnitChecklistsScreenState();
}

class _UnitChecklistsScreenState extends State<UnitChecklistsScreen> {
  late final UnitChecklistKindsViewModel _viewModel =
      widget.viewModel ?? UnitChecklistKindsViewModel(widget.repository);

  @override
  void initState() {
    super.initState();
    unawaited(_viewModel.load());
  }

  @override
  void dispose() {
    if (widget.viewModel == null) {
      _viewModel.dispose();
    }
    super.dispose();
  }

  Future<void> _open(UnitChecklistKind kind) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            UnitChecklistScreen(repository: widget.repository, kind: kind),
      ),
    );
    // The counts on this list are the checklist's; re-read them on return.
    if (mounted) unawaited(_viewModel.load());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) => PointyScaffold(
        appBar: PointyAppBar(
          title: Text(l10n.unitChecklistsTitle),
          isLoading: _viewModel.isLoading,
          actions: [
            IconButton(
              tooltip: l10n.retryButton,
              onPressed: _viewModel.isLoading ? null : _viewModel.load,
              icon: const Icon(Icons.sync),
            ),
          ],
        ),
        body: _body(context, l10n),
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final kinds = _viewModel.kinds;
    if (kinds.isEmpty) {
      final error = _viewModel.loadError;
      if (error != null) {
        return PointyErrorState(
          title: l10n.unitChecklistsLoadError,
          message: errorMessageFor(error, l10n),
          icon: Icons.cloud_off_outlined,
          action: FilledButton.icon(
            onPressed: _viewModel.load,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.retryButton),
          ),
        );
      }
      if (_viewModel.isLoading) {
        return const PointyLoadingArea();
      }
      return PointyEmptyState(
        icon: Icons.devices_other_outlined,
        title: l10n.unitChecklistsEmptyTitle,
        message: l10n.unitChecklistsEmptyBody,
      );
    }
    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.unitChecklistsHint,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
              SizedBox(height: spacing.sm),
              PointySettingsSection(
                children: [
                  for (final kind in kinds)
                    PointySettingsTile(
                      key: ValueKey('unit-checklist-kind-${kind.assetTypeId}'),
                      icon: assetIconForKey(kind.iconKey),
                      title: kind.name,
                      subtitle: _countLine(l10n, kind),
                      onTap: () => _open(kind),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _countLine(AppLocalizations l10n, UnitChecklistKind kind) {
    return [
      l10n.unitChecklistFieldCount(kind.fieldCount),
      if (kind.requiredCount > 0)
        l10n.unitChecklistRequiredCount(kind.requiredCount),
    ].join(' · ');
  }
}
