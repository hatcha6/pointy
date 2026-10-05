import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/error_messages.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/missing_lots_view_model.dart';
import 'lot_chooser_sheet.dart';
import 'missing_lots_units_pane.dart';

/// The missing-lot worklist (§4.2): units on the shelf from before their
/// product started tracking lots, given the lot printed on their box.
///
/// The shape of the opening-identification run beside it — products owing
/// work, then the articles of the one in hand — because it is the same job:
/// a person with a pile of boxes, naming what the system cannot guess. Nothing
/// moves. The lot's balance takes the units and the shelf is worth exactly
/// what it was.
class MissingLotsScreen extends StatefulWidget {
  const MissingLotsScreen({
    super.key,
    required this.viewModel,
    required this.canAssign,
  });

  final MissingLotsViewModel viewModel;

  /// `inventory.add_stockunit` — the same right that names an identifier.
  final bool canAssign;

  @override
  State<MissingLotsScreen> createState() => _MissingLotsScreenState();
}

class _MissingLotsScreenState extends State<MissingLotsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.viewModel.load());
      }
    });
  }

  Future<void> _assign() async {
    final viewModel = widget.viewModel;
    final group = viewModel.group;
    if (group == null || viewModel.selectedCount == 0) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final choice = await showLotChooserSheet(
      context,
      productLabel: group.title,
      count: viewModel.selectedCount,
      lots: viewModel.lots,
      expiryRequired: group.expiryRequired,
    );
    if (choice == null || !mounted) {
      return;
    }
    final done = await viewModel.assign(choice);
    if (!mounted) {
      return;
    }
    final error = viewModel.assignError;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            done != null
                ? l10n.missingLotsAssigned(
                    done.assigned,
                    done.batchCode.isEmpty
                        ? choice.displayCode
                        : done.batchCode,
                  )
                : errorMessageFor(error ?? StateError(''), l10n),
          ),
        ),
      );
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
            title: Text(l10n.missingLotsTitle),
            isLoading: viewModel.isAssigning,
            actions: [
              IconButton(
                tooltip: l10n.refreshShopSettingsTooltip,
                onPressed: viewModel.isLoadingGroups ? null : viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: BarcodeScanListener(
            // A scan anywhere on the screen ticks the pack it reads.
            onBarcodeScanned: (code) => unawaited(viewModel.scan(code)),
            child: _body(context, l10n, viewModel),
          ),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    MissingLotsViewModel viewModel,
  ) {
    if (viewModel.groups.isEmpty) {
      if (viewModel.isLoadingGroups) {
        return const _GroupsSkeleton();
      }
      if (viewModel.groupsFailed) {
        return PointyErrorState(
          title: l10n.missingLotsTitle,
          icon: Icons.inventory_2_outlined,
          action: FilledButton.icon(
            onPressed: viewModel.load,
            icon: const Icon(Icons.sync),
            label: Text(l10n.retryButton),
          ),
        );
      }
      return PointyEmptyState(
        icon: Icons.check_circle_outline,
        title: l10n.missingLotsEmpty,
        message: l10n.missingLotsBody,
      );
    }
    final units = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: MissingLotsUnitsPane(viewModel: viewModel)),
        if (widget.canAssign && viewModel.group != null)
          _AssignFooter(viewModel: viewModel, onAssign: _assign),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= AppBreakpoints.tabletMin;
        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _GroupStrip(viewModel: viewModel),
              Expanded(child: units),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 340, child: _GroupList(viewModel: viewModel)),
            const VerticalDivider(width: 1),
            Expanded(child: units),
          ],
        );
      },
    );
  }
}

/// Wide screens: the products owing lots, as a list on the start side.
class _GroupList extends StatelessWidget {
  const _GroupList({required this.viewModel});

  final MissingLotsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    return ListView(
      padding: spacing.pagePadding,
      children: [
        PointyDetailCallout(
          icon: Icons.inventory_2_outlined,
          tone: PointyCalloutTone.warning,
          title: l10n.missingLotsCount(viewModel.totalOutstanding),
          message: l10n.missingLotsBody,
        ),
        SizedBox(height: spacing.md),
        PointySectionHeader(title: l10n.missingLotsProductsHeader),
        for (final group in viewModel.groups)
          ListTile(
            key: ValueKey('missing_lot_group_${group.variantId}'),
            selected: group.variantId == viewModel.variantId,
            selectedColor: colors.primaryStrong,
            selectedTileColor: PointyColors.primaryContainer.withValues(
              alpha: 0.35,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text(
              group.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: group.sku.isEmpty ? null : Text(group.sku),
            trailing: PointyStatusPill(
              label: '${group.count}',
              color: colors.warning,
            ),
            onTap: () => viewModel.selectGroup(group.variantId),
          ),
      ],
    );
  }
}

/// Phones: the same products as a strip of chips over the units.
class _GroupStrip extends StatelessWidget {
  const _GroupStrip({required this.viewModel});

  final MissingLotsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    return Padding(
      padding: spacing.pagePadding.copyWith(bottom: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointyDetailCallout(
            icon: Icons.inventory_2_outlined,
            tone: PointyCalloutTone.warning,
            title: l10n.missingLotsCount(viewModel.totalOutstanding),
            message: l10n.missingLotsBody,
          ),
          SizedBox(height: spacing.sm),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final group in viewModel.groups)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: ChoiceChip(
                      key: ValueKey('missing_lot_group_${group.variantId}'),
                      label: Text('${group.title} · ${group.count}'),
                      selected: group.variantId == viewModel.variantId,
                      onSelected: (_) => viewModel.selectGroup(group.variantId),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AssignFooter extends StatelessWidget {
  const _AssignFooter({required this.viewModel, required this.onAssign});

  final MissingLotsViewModel viewModel;
  final VoidCallback onAssign;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final count = viewModel.selectedCount;
    return PointyStickyActionFooter(
      summary: Row(
        children: [
          Expanded(
            child: Text(
              l10n.missingLotsSelected(count),
              style: PointyTypography.numeric(
                Theme.of(context).textTheme.titleSmall ?? const TextStyle(),
              ),
            ),
          ),
          if (count > 0)
            TextButton(
              onPressed: viewModel.clearSelection,
              child: Text(l10n.missingLotsClearSelection),
            ),
        ],
      ),
      primaryAction: FilledButton.icon(
        key: const ValueKey('missing_lots_assign'),
        onPressed: count == 0 || viewModel.isAssigning ? null : onAssign,
        icon: const Icon(Icons.inventory_2_outlined),
        label: Text(l10n.missingLotsAssignAction),
      ),
    );
  }
}

class _GroupsSkeleton extends StatelessWidget {
  const _GroupsSkeleton();

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return PointySkeleton(
      child: ListView(
        padding: spacing.pagePadding,
        physics: const NeverScrollableScrollPhysics(),
        children: const [
          PointySkeletonBox(height: 72),
          SizedBox(height: 16),
          PointySkeletonListTile(),
          PointySkeletonListTile(),
          PointySkeletonListTile(),
        ],
      ),
    );
  }
}

/// Opens the worklist on its own view model — shop-wide, or one product's when
/// [productId] is given — and resolves once it is closed, so the caller can
/// refresh whatever count sent the person there.
Future<void> openMissingLotsScreen(
  BuildContext context, {
  required TrackedStockRepository repository,
  required bool canAssign,
  int? productId,
}) async {
  final viewModel = MissingLotsViewModel(repository, productId: productId);
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          MissingLotsScreen(viewModel: viewModel, canAssign: canAssign),
    ),
  );
  viewModel.dispose();
}
