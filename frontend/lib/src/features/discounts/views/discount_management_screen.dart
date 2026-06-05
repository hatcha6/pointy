import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/discount_rule.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/discount_management_view_model.dart';
import 'discount_rule_query_controls.dart';
import 'discount_rule_form.dart';

class DiscountManagementScreen extends StatelessWidget {
  const DiscountManagementScreen({
    super.key,
    required this.viewModel,
    required this.catalogRepository,
    required this.contactRepository,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenInvoices,
    required this.onOpenCatalog,
    required this.onOpenCategories,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDashboard,
    this.onOpenReports,
    this.onOpenActivityLog,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final DiscountManagementViewModel viewModel;
  final CatalogRepository catalogRepository;
  final ContactRepository contactRepository;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenInvoices;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenCategories;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDashboard;
  final VoidCallback? onOpenReports;
  final VoidCallback? onOpenActivityLog;
  final VoidCallback? onOpenUsers;
  final VoidCallback? onOpenShopSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.discounts,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenDashboard: onOpenDashboard,
            onOpenPos: onOpenPos,
            onOpenInvoices: onOpenInvoices,
            onOpenPurchasing: onOpenPurchasing,
            onOpenContacts: onOpenContacts,
            onOpenCatalog: onOpenCatalog,
            onOpenCategories: onOpenCategories,
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenDeviceSettings: onOpenDeviceSettings,
            onOpenDiscounts: () {},
            onOpenReports: onOpenReports,
            onOpenActivityLog: onOpenActivityLog,
            onOpenUsers: onOpenUsers,
            onOpenShopSettings: onOpenShopSettings,
            onLogout: onLogout,
          ),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.discountManagementTitle),
            actions: [
              AuthorizationGuard(
                capabilities: capabilities,
                capability: AppCapability.viewDiscountRules,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshDiscountsTooltip,
                  onPressed: viewModel.isSaving ? null : viewModel.loadRules,
                  icon: const Icon(Icons.sync),
                ),
              ),
            ],
          ),
          body: AuthorizationGuard(
            capabilities: capabilities,
            capability: AppCapability.viewDiscountRules,
            child: _DiscountManagementBody(
              viewModel: viewModel,
              catalogRepository: catalogRepository,
              contactRepository: contactRepository,
              capabilities: capabilities,
              onCreateRule: viewModel.isSaving
                  ? null
                  : () => _showRuleForm(context),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showRuleForm(BuildContext context, {DiscountRule? rule}) {
    return showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.expanded,
      maxHeightFactor: 0.94,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: DiscountRuleForm(
            viewModel: viewModel,
            catalogRepository: catalogRepository,
            contactRepository: contactRepository,
            rule: rule,
            onSaved: () => Navigator.of(sheetContext).pop(),
          ),
        );
      },
    );
  }
}

class _DiscountManagementBody extends StatelessWidget {
  const _DiscountManagementBody({
    required this.viewModel,
    required this.catalogRepository,
    required this.contactRepository,
    required this.capabilities,
    required this.onCreateRule,
  });

  final DiscountManagementViewModel viewModel;
  final CatalogRepository catalogRepository;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final VoidCallback? onCreateRule;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: spacing.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ResponsiveActionBar(
            alignment: WrapAlignment.start,
            actions: [
              if (capabilities.canCreateDiscountRule)
                FilledButton.icon(
                  onPressed: onCreateRule,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.discountCreateButton),
                ),
            ],
          ),
          SizedBox(height: spacing.sm),
          DiscountRuleQueryControls(
            query: viewModel.query,
            onSearchChanged: viewModel.updateSearch,
            onQueryChanged: viewModel.applyQuery,
            enabled: !viewModel.isLoading,
          ),
          SizedBox(height: spacing.sm),
          if (viewModel.hasSaveError)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l10n.discountSaveError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: PointyDataList<DiscountRule>(
              items: viewModel.rules,
              onLoadMore: viewModel.loadMoreRules,
              hasMore: viewModel.hasMoreRules,
              isLoadingInitial: viewModel.isLoading,
              isLoadingMore: viewModel.isLoadingMore,
              hasError: viewModel.hasLoadError,
              errorBuilder: (context) => PointyErrorState(
                title: l10n.discountLoadError,
                icon: Icons.local_offer_outlined,
              ),
              emptyBuilder: (context) => PointyEmptyState(
                icon: Icons.local_offer_outlined,
                title: l10n.discountEmptyRules,
              ),
              itemBuilder: (context, rule) {
                return _DiscountRuleTile(
                  rule: rule,
                  viewModel: viewModel,
                  capabilities: capabilities,
                  onEdit: () => _openForm(context, rule),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openForm(BuildContext context, DiscountRule rule) {
    return showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.expanded,
      maxHeightFactor: 0.94,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: DiscountRuleForm(
            viewModel: viewModel,
            catalogRepository: catalogRepository,
            contactRepository: contactRepository,
            rule: rule,
            onSaved: () => Navigator.of(sheetContext).pop(),
          ),
        );
      },
    );
  }
}

class _DiscountRuleTile extends StatelessWidget {
  const _DiscountRuleTile({
    required this.rule,
    required this.viewModel,
    required this.capabilities,
    required this.onEdit,
  });

  final DiscountRule rule;
  final DiscountManagementViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final canChange = capabilities.canChangeDiscountRule && !viewModel.isSaving;
    final canDelete = capabilities.canDeleteDiscountRule && !viewModel.isSaving;
    final facts = [
      if (rule.description.isNotEmpty) rule.description,
      ..._ruleFacts(l10n, rule),
    ];

    return PointyDataRow(
      leading: CircleAvatar(
        backgroundColor: rule.isActive
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest,
        foregroundColor: rule.isActive
            ? colorScheme.onPrimaryContainer
            : colorScheme.onSurfaceVariant,
        child: Icon(
          rule.applicationType == DiscountApplicationType.couponCode
              ? Icons.confirmation_number_outlined
              : Icons.auto_awesome_outlined,
        ),
      ),
      title: rule.name,
      subtitle: facts.join(' • '),
      badges: [
        _StatusChip(
          label: rule.isActive
              ? l10n.discountStatusActive
              : l10n.discountStatusInactive,
          icon: rule.isActive
              ? Icons.check_circle_outline
              : Icons.pause_circle_outline,
        ),
        _StatusChip(
          label: _channelLabel(l10n, rule.channel),
          icon: Icons.compare_arrows_outlined,
        ),
        _StatusChip(
          label: _applicationLabel(l10n, rule.applicationType),
          icon: Icons.rule_folder_outlined,
        ),
        _StatusChip(
          label: _scopeLabel(l10n, rule.scope),
          icon: Icons.view_list_outlined,
        ),
        if (rule.exclusive)
          _StatusChip(
            label: l10n.discountExclusiveShort,
            icon: Icons.block_outlined,
          ),
        if (rule.isArchived)
          _StatusChip(
            label: l10n.discountArchivedLabel,
            icon: Icons.archive_outlined,
          ),
      ],
      actions: [
        _RuleActions(
          rule: rule,
          canChange: canChange,
          canDelete: canDelete,
          onEdit: onEdit,
          onToggle: () => _toggleRule(context),
          onArchive: () => _confirmArchive(context),
        ),
      ],
    );
  }

  Future<void> _toggleRule(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final saved = await viewModel.setRuleActive(rule, !rule.isActive);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved
              ? rule.isActive
                    ? l10n.discountDisabledMessage
                    : l10n.discountEnabledMessage
              : l10n.discountSaveError,
        ),
      ),
    );
  }

  Future<void> _confirmArchive(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final shouldArchive = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          icon: const Icon(Icons.archive_outlined),
          title: Text(l10n.discountArchiveTitle),
          content: Text(l10n.discountArchiveMessage(rule.name)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.cancelButton),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.discountArchiveConfirmButton),
            ),
          ],
        );
      },
    );
    if (shouldArchive != true || !context.mounted) {
      return;
    }

    final saved = await viewModel.archiveRule(rule);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved ? l10n.discountArchivedMessage : l10n.discountSaveError,
        ),
      ),
    );
  }

  String _channelLabel(AppLocalizations l10n, DiscountChannel channel) {
    return switch (channel) {
      DiscountChannel.sales => l10n.discountChannelSales,
      DiscountChannel.purchasing => l10n.discountChannelPurchasing,
      DiscountChannel.both => l10n.discountChannelBoth,
    };
  }

  String _applicationLabel(
    AppLocalizations l10n,
    DiscountApplicationType type,
  ) {
    return switch (type) {
      DiscountApplicationType.automatic => l10n.discountApplicationAutomatic,
      DiscountApplicationType.couponCode => l10n.discountApplicationCoupon,
    };
  }

  String _scopeLabel(AppLocalizations l10n, DiscountScope scope) {
    return switch (scope) {
      DiscountScope.document => l10n.discountScopeDocument,
      DiscountScope.line => l10n.discountScopeLine,
    };
  }
}

List<String> _ruleFacts(AppLocalizations l10n, DiscountRule rule) {
  return [
    l10n.discountValueSummary(
      _valueTypeLabel(l10n, rule.valueType),
      _valueText(l10n, rule),
    ),
    l10n.discountPrioritySummary(rule.priority),
    if (rule.couponCode.isNotEmpty) l10n.discountCouponSummary(rule.couponCode),
    if (rule.minOrderSubtotal > 0)
      l10n.discountMinSubtotalSummary(formatMoney(rule.minOrderSubtotal)),
    if (rule.minLineQuantity != null)
      l10n.discountMinLineQuantitySummary(rule.minLineQuantity!),
    if (rule.maxDiscountAmount != null)
      l10n.discountMaxAmountSummary(formatMoney(rule.maxDiscountAmount!)),
    if (rule.usageLimit != null)
      l10n.discountUsageSummary(rule.redemptionCount, rule.usageLimit!),
    if (rule.usageLimit == null)
      l10n.discountUsageCountSummary(rule.redemptionCount),
    l10n.discountAppliedCountSummary(rule.appliedCount),
    if (rule.startsAt != null)
      l10n.discountStartsAtSummary(formatDateTime(rule.startsAt!)),
    if (rule.endsAt != null)
      l10n.discountEndsAtSummary(formatDateTime(rule.endsAt!)),
    if (rule.products.isNotEmpty)
      l10n.discountProductConstraintSummary(rule.products.length),
    if (rule.variants.isNotEmpty)
      l10n.discountVariantConstraintSummary(rule.variants.length),
    if (rule.productCategories.isNotEmpty)
      l10n.discountProductCategoryConstraintSummary(
        rule.productCategories.length,
      ),
    if (rule.customers.isNotEmpty)
      l10n.discountCustomerConstraintSummary(rule.customers.length),
    if (rule.suppliers.isNotEmpty)
      l10n.discountSupplierConstraintSummary(rule.suppliers.length),
  ];
}

String _valueText(AppLocalizations l10n, DiscountRule rule) {
  return switch (rule.valueType) {
    DiscountValueType.percentage => l10n.discountPercentageValue(
      rule.value.toStringAsFixed(2),
    ),
    DiscountValueType.fixedAmount ||
    DiscountValueType.fixedUnitAmount ||
    DiscountValueType.fixedPrice => formatMoney(rule.value),
  };
}

String _valueTypeLabel(AppLocalizations l10n, DiscountValueType type) {
  return switch (type) {
    DiscountValueType.percentage => l10n.discountValueTypePercentage,
    DiscountValueType.fixedAmount => l10n.discountValueTypeFixedAmount,
    DiscountValueType.fixedUnitAmount => l10n.discountValueTypeFixedUnitAmount,
    DiscountValueType.fixedPrice => l10n.discountValueTypeFixedPrice,
  };
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return PointyStatusPill(label: label, icon: icon);
  }
}

class _RuleActions extends StatelessWidget {
  const _RuleActions({
    required this.rule,
    required this.canChange,
    required this.canDelete,
    required this.onEdit,
    required this.onToggle,
    required this.onArchive,
  });

  final DiscountRule rule;
  final bool canChange;
  final bool canDelete;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onArchive;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      alignment: WrapAlignment.end,
      children: [
        IconButton.filledTonal(
          tooltip: l10n.discountEditTooltip,
          onPressed: canChange ? onEdit : null,
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton.filledTonal(
          tooltip: rule.isActive
              ? l10n.discountDisableTooltip
              : l10n.discountEnableTooltip,
          onPressed: canChange ? onToggle : null,
          icon: Icon(
            rule.isActive
                ? Icons.pause_circle_outline
                : Icons.play_circle_outline,
          ),
        ),
        IconButton.filledTonal(
          tooltip: l10n.discountArchiveTooltip,
          onPressed: canDelete ? onArchive : null,
          icon: const Icon(Icons.archive_outlined),
        ),
      ],
    );
  }
}
