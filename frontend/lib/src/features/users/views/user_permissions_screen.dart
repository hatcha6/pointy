import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/permission_catalog.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/query_controls/debounced_search_field.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../role_presentation.dart';
import '../view_models/user_permissions_view_model.dart';

/// Full-screen editor for a user's directly-granted (extra) permissions, on top
/// of whatever their role already provides. Role permissions are shown locked.
class UserPermissionsScreen extends StatelessWidget {
  const UserPermissionsScreen({super.key, required this.viewModel});

  final UserPermissionsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    // Saving pops explicitly from _SaveFooter, which PopScope does not
    // intercept — so a successful save still closes the editor normally.
    return PointyUnsavedChangesGuard(
      isDirty: () => viewModel.hasChanges,
      child: _buildScaffold(),
    );
  }

  Widget _buildScaffold() {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.userPermissionsTitle(viewModel.user.label)),
            isLoading: viewModel.isLoading || viewModel.isSaving,
          ),
          bottomNavigationBar: viewModel.isEditable && !viewModel.isLoading
              ? _SaveFooter(viewModel: viewModel)
              : null,
          body: _buildBody(context, l10n),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    if (viewModel.isLoading && !viewModel.isReady) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasError && !viewModel.isReady) {
      return PointyErrorState(
        title: l10n.permissionsLoadError,
        icon: Icons.lock_outline,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    final spacing = AdaptiveSpacing.of(context);

    if (!viewModel.isEditable) {
      return Center(
        child: AdaptiveMaxWidth(
          width: AppContentWidth.compact,
          padding: spacing.pagePadding,
          child: PointyDetailCallout(
            icon: Icons.admin_panel_settings_outlined,
            title: roleLabelFor(context, viewModel.user.role),
            message: l10n.permissionsManagerHasAll,
            tone: PointyCalloutTone.neutral,
          ),
        ),
      );
    }

    final groups = viewModel.visibleGroups;

    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.detail,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PointyDetailCallout(
                icon: Icons.verified_user_outlined,
                title: roleLabelFor(context, viewModel.user.role),
                message: l10n.permissionsSummaryInheritedExtra(
                  viewModel.inheritedCount,
                  viewModel.extraCount,
                ),
              ),
              SizedBox(height: spacing.md),
              DebouncedSearchField(
                value: viewModel.search,
                hintText: l10n.permissionsSearchHint,
                clearTooltip: l10n.clearButton,
                onChanged: viewModel.setSearch,
              ),
              SizedBox(height: spacing.sm),
              if (groups.isEmpty)
                PointyEmptyState(
                  icon: Icons.search_off_outlined,
                  title: l10n.permissionsEmpty,
                )
              else
                for (final group in groups) ...[
                  _PermissionGroupSection(viewModel: viewModel, group: group),
                  SizedBox(height: spacing.md),
                ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SaveFooter extends StatelessWidget {
  const _SaveFooter({required this.viewModel});

  final UserPermissionsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final canSave = viewModel.hasChanges && !viewModel.isSaving;
    return PointyStickyActionFooter(
      summary: viewModel.hasSaveError
          ? Text(
              viewModel.saveFailure?.describe(l10n) ??
                  l10n.permissionsSaveError,
              style: TextStyle(color: context.pointyColors.danger),
            )
          : null,
      primaryAction: FilledButton.icon(
        onPressed: canSave ? () => _save(context) : null,
        icon: viewModel.isSaving
            ? const SizedBox.square(
                dimension: 18,
                child: PointySpinner(strokeWidth: 2),
              )
            : const Icon(Icons.check),
        label: Text(l10n.permissionsSaveButton),
      ),
    );
  }

  Future<void> _save(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final saved = await viewModel.save();
    if (!saved) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.permissionsSavedMessage)),
    );
    navigator.pop(viewModel.user);
  }
}

class _PermissionGroupSection extends StatelessWidget {
  const _PermissionGroupSection({required this.viewModel, required this.group});

  final UserPermissionsViewModel viewModel;
  final PermissionCatalogGroup group;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final granted = viewModel.grantedInGroup(group);
    final fullyGranted = viewModel.isGroupFullyGranted(group);
    final hasToggleable = group.permissions.any(viewModel.canToggle);

    return PointyDetailSection(
      title: group.label,
      icon: _groupIcon(group.key),
      trailing: hasToggleable
          ? TextButton(
              onPressed: () => viewModel.setGroup(group, !fullyGranted),
              child: Text(
                fullyGranted
                    ? l10n.permissionsClearGroup
                    : l10n.permissionsSelectGroup,
              ),
            )
          : PointyStatusPill(
              label: '$granted/${group.permissions.length}',
              color: context.pointyColors.mutedInk,
              compact: true,
            ),
      child: Column(
        children: [
          for (final (index, entry) in group.permissions.indexed) ...[
            if (index > 0) const Divider(height: 1),
            _PermissionRow(viewModel: viewModel, entry: entry),
          ],
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.viewModel, required this.entry});

  final UserPermissionsViewModel viewModel;
  final PermissionCatalogEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final fromRole = viewModel.isInRole(entry.code);
    final granted = viewModel.isGranted(entry.code);
    final toggleable = viewModel.canToggle(entry);

    return InkWell(
      onTap: toggleable
          ? () => viewModel.toggle(entry, !viewModel.isExtra(entry.code))
          : null,
      borderRadius: BorderRadius.circular(PointyRadii.chip),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: granted,
              onChanged: toggleable
                  ? (value) => viewModel.toggle(entry, value ?? false)
                  : null,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.label,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  if (entry.description.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      entry.description,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (fromRole)
              PointyStatusPill(
                label: l10n.permissionsInheritedFromRole,
                icon: Icons.lock_outline,
                color: colors.mutedInk,
                compact: true,
              )
            else if (!entry.grantable)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  l10n.permissionsNeedsHigherPermission,
                  textAlign: TextAlign.end,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: colors.warning),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

IconData _groupIcon(String key) {
  return switch (key) {
    'catalog' => Icons.sell_outlined,
    'product_setup' => Icons.straighten_outlined,
    'recipes' => Icons.menu_book_outlined,
    'scales' => Icons.scale_outlined,
    'inventory' => Icons.inventory_2_outlined,
    'warehouses' => Icons.warehouse_outlined,
    'sales' => Icons.point_of_sale_outlined,
    'payments' => Icons.payments_outlined,
    'treasury' => Icons.account_balance_outlined,
    'purchasing' => Icons.local_shipping_outlined,
    'contacts' => Icons.people_alt_outlined,
    'assets' => Icons.devices_other_outlined,
    'discounts' => Icons.local_offer_outlined,
    'expenses' => Icons.account_balance_wallet_outlined,
    'operations' => Icons.handyman_outlined,
    'employees' => Icons.badge_outlined,
    'reports' => Icons.insights_outlined,
    'attendance' => Icons.how_to_reg_outlined,
    'fraud' => Icons.shield_outlined,
    'settings' => Icons.settings_outlined,
    'printing' => Icons.print_outlined,
    'print_setup' => Icons.receipt_long_outlined,
    'integrations' => Icons.extension_outlined,
    'fx' => Icons.currency_exchange_outlined,
    'users' => Icons.manage_accounts_outlined,
    'messaging' => Icons.sms_outlined,
    'surveillance' => Icons.videocam_outlined,
    'files' => Icons.attach_file,
    'migration' => Icons.cloud_sync_outlined,
    _ => Icons.lock_outline,
  };
}
