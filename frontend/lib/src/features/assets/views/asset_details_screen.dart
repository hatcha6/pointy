import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/customer_asset.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/asset_details_view_model.dart';
import 'assets_ui.dart';

/// One item's whole story.
///
/// The history belongs to the *item*, not to whoever owned it at the time, so a
/// second-hand phone or a used car carries its service record across owners —
/// which is the reason a shop keeps a registry at all.
class AssetDetailsScreen extends StatefulWidget {
  const AssetDetailsScreen({
    super.key,
    required this.viewModel,
    required this.capabilities,
    required this.contactRepository,
    this.onNewJob,
  });

  final AssetDetailsViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final ContactRepository contactRepository;
  final void Function(CustomerAsset asset)? onNewJob;

  @override
  State<AssetDetailsScreen> createState() => _AssetDetailsScreenState();
}

class _AssetDetailsScreenState extends State<AssetDetailsScreen> {
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
        final detail = viewModel.detail;

        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(
              detail == null
                  ? l10n.assetsTitle
                  : assetTitle(l10n, detail.asset),
            ),
            isLoading: viewModel.isLoading || viewModel.isMutating,
            reserveLoadingSlot: false,
          ),
          body: _body(context, l10n),
        );
      },
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final detail = viewModel.detail;
    final spacing = AdaptiveSpacing.of(context);

    if (detail == null) {
      if (viewModel.isLoading) {
        return const PointyLoadingArea();
      }
      return PointyErrorState(
        title: l10n.assetsLoadErrorDetail,
        icon: Icons.devices_other_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    final asset = detail.asset;
    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.detail,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _hero(context, l10n, detail),
              SizedBox(height: spacing.md),
              PointyMetricGrid(
                metrics: [
                  PointyMetricGridItem(
                    label: l10n.assetVisitsMetric,
                    value: '${asset.jobCount}',
                    icon: Icons.build_outlined,
                  ),
                  PointyMetricGridItem(
                    label: l10n.assetTotalSpentMetric,
                    value: formatMoney(detail.totalSpent),
                    icon: Icons.payments_outlined,
                  ),
                  PointyMetricGridItem(
                    label: l10n.assetLastVisitMetric,
                    value: asset.lastJobAt == null
                        ? l10n.assetNeverVisited
                        : formatDate(asset.lastJobAt!),
                    icon: Icons.history,
                  ),
                ],
              ),
              SizedBox(height: spacing.md),
              if (widget.onNewJob != null) ...[
                FilledButton.icon(
                  onPressed: () => widget.onNewJob!(asset),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.assetNewJobButton),
                ),
                SizedBox(height: spacing.md),
              ],
              _identitySection(context, l10n, asset),
              SizedBox(height: spacing.md),
              _ownershipSection(context, l10n, detail),
              SizedBox(height: spacing.md),
              _historySection(context, l10n, detail),
            ],
          ),
        ),
      ],
    );
  }

  Widget _hero(
    BuildContext context,
    AppLocalizations l10n,
    CustomerAssetDetail detail,
  ) {
    final asset = detail.asset;
    return PointyDetailHero(
      icon: assetTypeIcon(asset.assetType),
      title: assetTitle(l10n, asset),
      value: asset.identityLabel.isEmpty ? null : asset.identityLabel,
      valueSubtitle: assetTypeName(l10n, asset.assetType),
      description: asset.notes.trim().isEmpty ? null : asset.notes.trim(),
      pills: [
        if (asset.isInShop)
          PointyHeroPill(
            label: l10n.assetInShopBadge,
            icon: Icons.home_repair_service_outlined,
          ),
        if (asset.customerName.trim().isNotEmpty)
          PointyHeroPill(label: asset.customerName, icon: Icons.person_outline),
        if (asset.modelYear != null)
          PointyHeroPill(
            label: '${asset.modelYear}',
            icon: Icons.calendar_today_outlined,
          ),
      ],
    );
  }

  Widget _identitySection(
    BuildContext context,
    AppLocalizations l10n,
    CustomerAsset asset,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final fields = assetIdentityFields(l10n, asset);
    if (asset.odometer != null) {
      fields.add((label: l10n.assetOdometerLabel, value: '${asset.odometer}'));
    }
    if (fields.isEmpty) {
      return const SizedBox.shrink();
    }
    return PointyDetailSection(
      title: l10n.assetIdentitySectionTitle,
      icon: Icons.badge_outlined,
      child: Wrap(
        spacing: spacing.lg,
        runSpacing: spacing.sm,
        children: [
          for (final field in fields)
            AssetIdentityChip(label: field.label, value: field.value),
        ],
      ),
    );
  }

  Widget _ownershipSection(
    BuildContext context,
    AppLocalizations l10n,
    CustomerAssetDetail detail,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return PointyDetailSection(
      title: l10n.assetOwnershipHistoryTitle,
      icon: Icons.people_outline,
      trailing: widget.capabilities.canManageAssets
          ? TextButton.icon(
              onPressed: widget.viewModel.isMutating
                  ? null
                  : () => _openTransferDialog(detail.asset),
              icon: const Icon(Icons.swap_horiz),
              label: Text(l10n.assetTransferButton),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final ownership in detail.ownerships)
            Padding(
              padding: EdgeInsetsDirectional.only(bottom: spacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    ownership.isCurrent
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: ownership.isCurrent
                        ? colors.primaryStrong
                        : colors.mutedInk,
                  ),
                  SizedBox(width: spacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ownership.customerName,
                          style: textTheme.bodyMedium?.copyWith(
                            fontWeight: ownership.isCurrent
                                ? FontWeight.w800
                                : FontWeight.w600,
                          ),
                        ),
                        Text(
                          _ownershipPeriod(l10n, ownership),
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                        if (ownership.note.trim().isNotEmpty)
                          Text(
                            ownership.note,
                            style: textTheme.bodySmall?.copyWith(
                              color: colors.mutedInk,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (ownership.isCurrent)
                    PointyStatusPill(
                      label: l10n.assetOwnershipCurrent,
                      icon: Icons.person_outline,
                      color: colors.primaryStrong,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _ownershipPeriod(AppLocalizations l10n, AssetOwnership ownership) {
    final from = ownership.acquiredAt;
    final to = ownership.releasedAt;
    if (from == null) {
      return '';
    }
    if (to == null) {
      return l10n.assetOwnershipSince(formatDate(from));
    }
    return l10n.assetOwnershipRange(formatDate(from), formatDate(to));
  }

  Widget _historySection(
    BuildContext context,
    AppLocalizations l10n,
    CustomerAssetDetail detail,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return PointyDetailSection(
      title: l10n.assetHistoryTitle,
      icon: Icons.history,
      child: detail.jobs.isEmpty
          ? Text(
              l10n.assetNoHistoryMessage,
              style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in detail.jobs)
                  Padding(
                    padding: EdgeInsetsDirectional.only(bottom: spacing.sm),
                    child: _HistoryRow(entry: entry),
                  ),
              ],
            ),
    );
  }

  Future<void> _openTransferDialog(CustomerAsset asset) async {
    final l10n = AppLocalizations.of(context)!;
    final customer = await showCustomerPickerSheet(
      context: context,
      repository: widget.contactRepository,
    );
    if (customer == null || !mounted) {
      return;
    }
    final noteController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.assetTransferDialogTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.assetTransferExplainer),
            const SizedBox(height: 12),
            Text(
              customer.fullName,
              style: Theme.of(
                dialogContext,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              decoration: InputDecoration(
                labelText: l10n.assetTransferNoteLabel,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.assetTransferConfirm),
          ),
        ],
      ),
    );
    final note = noteController.text;
    noteController.dispose();
    if (confirmed != true || !mounted) {
      return;
    }
    final ok = await widget.viewModel.transfer(
      customerId: customer.id,
      note: note,
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? l10n.assetTransferSuccess(customer.fullName)
              : widget.viewModel.mutationError,
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry});

  final AssetJobHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final subtitle = [
      if (entry.diagnosis.trim().isNotEmpty)
        entry.diagnosis.trim()
      else if (entry.symptoms.trim().isNotEmpty)
        entry.symptoms.trim(),
      if (entry.customerName.trim().isNotEmpty) entry.customerName.trim(),
    ].join(' · ');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          entry.isOpen ? Icons.timelapse_outlined : Icons.check_circle_outline,
          size: 18,
          color: entry.isOpen ? colors.primaryStrong : colors.success,
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
                      entry.jobNumber,
                      style: PointyTypography.numeric(
                        textTheme.bodyMedium ?? const TextStyle(),
                      ).copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (entry.total != null)
                    Text(
                      formatMoney(entry.total!),
                      style: PointyTypography.numeric(
                        textTheme.bodyMedium ?? const TextStyle(),
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                ],
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              Text(
                [
                  if (entry.createdAt != null) formatDate(entry.createdAt!),
                  if (entry.isOpen)
                    entry.stageName
                  else if (entry.handedOverAt != null)
                    l10n.jobCustodyReleased,
                ].where((part) => part.trim().isNotEmpty).join(' · '),
                style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
