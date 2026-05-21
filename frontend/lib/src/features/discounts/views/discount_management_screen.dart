import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/discount_rule.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/query_controls/debounced_search_field.dart';
import '../view_models/discount_management_view_model.dart';
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
    required this.onOpenCatalog,
    required this.onOpenCategories,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDashboard,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final DiscountManagementViewModel viewModel;
  final CatalogRepository catalogRepository;
  final ContactRepository contactRepository;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenCategories;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDashboard;
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
            selectedDestination: AppNavigationDestination.discounts,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenDashboard: onOpenDashboard,
            onOpenPos: onOpenPos,
            onOpenPurchasing: onOpenPurchasing,
            onOpenContacts: onOpenContacts,
            onOpenCatalog: onOpenCatalog,
            onOpenCategories: onOpenCategories,
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenDeviceSettings: onOpenDeviceSettings,
            onOpenDiscounts: () {},
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
          body: SafeArea(
            child: AuthorizationGuard(
              capabilities: capabilities,
              capability: AppCapability.viewDiscountRules,
              child: _DiscountManagementBody(
                viewModel: viewModel,
                catalogRepository: catalogRepository,
                contactRepository: contactRepository,
                capabilities: capabilities,
              ),
            ),
          ),
          floatingActionButton: AuthorizationGuard(
            capabilities: capabilities,
            capability: AppCapability.createDiscountRule,
            fallback: const SizedBox.shrink(),
            child: FloatingActionButton.extended(
              onPressed: viewModel.isSaving
                  ? null
                  : () => _showRuleForm(context),
              icon: const Icon(Icons.add),
              label: Text(l10n.discountCreateButton),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showRuleForm(BuildContext context, {DiscountRule? rule}) {
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
          child: FractionallySizedBox(
            heightFactor: 0.94,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: DiscountRuleForm(
                  viewModel: viewModel,
                  catalogRepository: catalogRepository,
                  contactRepository: contactRepository,
                  rule: rule,
                  onSaved: () => Navigator.of(sheetContext).pop(),
                ),
              ),
            ),
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
  });

  final DiscountManagementViewModel viewModel;
  final CatalogRepository catalogRepository;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DiscountFilterBar(viewModel: viewModel),
          const SizedBox(height: 12),
          if (viewModel.hasSaveError)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l10n.discountSaveError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: viewModel.hasLoadError && viewModel.rules.isEmpty
                ? Center(child: Text(l10n.discountLoadError))
                : InfiniteScrollList<DiscountRule>(
                    items: viewModel.rules,
                    onLoadMore: viewModel.loadMoreRules,
                    hasMore: viewModel.hasMoreRules,
                    isLoadingInitial: viewModel.isLoading,
                    isLoadingMore: viewModel.isLoadingMore,
                    emptyBuilder: (context) {
                      return Center(child: Text(l10n.discountEmptyRules));
                    },
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
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
          child: FractionallySizedBox(
            heightFactor: 0.94,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: DiscountRuleForm(
                  viewModel: viewModel,
                  catalogRepository: catalogRepository,
                  contactRepository: contactRepository,
                  rule: rule,
                  onSaved: () => Navigator.of(sheetContext).pop(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DiscountFilterBar extends StatelessWidget {
  const _DiscountFilterBar({required this.viewModel});

  final DiscountManagementViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = viewModel.query;

    return LayoutBuilder(
      builder: (context, constraints) {
        final fieldWidth = constraints.maxWidth >= 900
            ? (constraints.maxWidth - 36) / 4
            : constraints.maxWidth >= 560
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DebouncedSearchField(
              value: query.search,
              hintText: l10n.discountSearchHint,
              clearTooltip: l10n.clearSearchTooltip,
              enabled: !viewModel.isLoading,
              onChanged: viewModel.updateSearch,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                SizedBox(
                  width: fieldWidth,
                  child: _FilterDropdown<DiscountRuleStatusFilter>(
                    label: l10n.discountStatusFilterLabel,
                    value: query.status,
                    values: DiscountRuleStatusFilter.values,
                    labelFor: (value) => _statusFilterLabel(l10n, value),
                    onChanged: (value) {
                      viewModel.applyQuery(query.copyWith(status: value));
                    },
                  ),
                ),
                SizedBox(
                  width: fieldWidth,
                  child: _FilterDropdown<DiscountRuleChannelFilter>(
                    label: l10n.discountChannelLabel,
                    value: query.channel,
                    values: DiscountRuleChannelFilter.values,
                    labelFor: (value) => _channelFilterLabel(l10n, value),
                    onChanged: (value) {
                      viewModel.applyQuery(query.copyWith(channel: value));
                    },
                  ),
                ),
                SizedBox(
                  width: fieldWidth,
                  child: _FilterDropdown<DiscountRuleApplicationFilter>(
                    label: l10n.discountApplicationTypeLabel,
                    value: query.application,
                    values: DiscountRuleApplicationFilter.values,
                    labelFor: (value) => _applicationFilterLabel(l10n, value),
                    onChanged: (value) {
                      viewModel.applyQuery(query.copyWith(application: value));
                    },
                  ),
                ),
                SizedBox(
                  width: fieldWidth,
                  child: _FilterDropdown<DiscountRuleOrdering>(
                    label: l10n.discountOrderingLabel,
                    value: query.ordering,
                    values: DiscountRuleOrdering.values,
                    labelFor: (value) => _orderingLabel(l10n, value),
                    onChanged: (value) {
                      viewModel.applyQuery(query.copyWith(ordering: value));
                    },
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  String _statusFilterLabel(
    AppLocalizations l10n,
    DiscountRuleStatusFilter value,
  ) {
    return switch (value) {
      DiscountRuleStatusFilter.all => l10n.discountFilterAll,
      DiscountRuleStatusFilter.active => l10n.discountStatusActive,
      DiscountRuleStatusFilter.inactive => l10n.discountStatusInactive,
    };
  }

  String _channelFilterLabel(
    AppLocalizations l10n,
    DiscountRuleChannelFilter value,
  ) {
    return switch (value) {
      DiscountRuleChannelFilter.all => l10n.discountFilterAll,
      DiscountRuleChannelFilter.sales => l10n.discountChannelSales,
      DiscountRuleChannelFilter.purchasing => l10n.discountChannelPurchasing,
      DiscountRuleChannelFilter.both => l10n.discountChannelBoth,
    };
  }

  String _applicationFilterLabel(
    AppLocalizations l10n,
    DiscountRuleApplicationFilter value,
  ) {
    return switch (value) {
      DiscountRuleApplicationFilter.all => l10n.discountFilterAll,
      DiscountRuleApplicationFilter.automatic =>
        l10n.discountApplicationAutomatic,
      DiscountRuleApplicationFilter.couponCode =>
        l10n.discountApplicationCoupon,
    };
  }

  String _orderingLabel(AppLocalizations l10n, DiscountRuleOrdering value) {
    return switch (value) {
      DiscountRuleOrdering.priority => l10n.discountOrderingPriority,
      DiscountRuleOrdering.name => l10n.discountOrderingName,
      DiscountRuleOrdering.newest => l10n.discountOrderingNewest,
      DiscountRuleOrdering.updated => l10n.discountOrderingUpdated,
    };
  }
}

class _FilterDropdown<T> extends StatelessWidget {
  const _FilterDropdown({
    required this.label,
    required this.value,
    required this.values,
    required this.labelFor,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<T> values;
  final String Function(T value) labelFor;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        for (final value in values)
          DropdownMenuItem(value: value, child: Text(labelFor(value))),
      ],
      onChanged: (value) {
        if (value != null) {
          onChanged(value);
        }
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

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final content = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      backgroundColor: rule.isActive
                          ? colorScheme.primaryContainer
                          : colorScheme.surfaceContainerHighest,
                      foregroundColor: rule.isActive
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                      child: Icon(
                        rule.applicationType ==
                                DiscountApplicationType.couponCode
                            ? Icons.confirmation_number_outlined
                            : Icons.auto_awesome_outlined,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            rule.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (rule.description.isNotEmpty)
                            Text(
                              rule.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
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
                                label: _applicationLabel(
                                  l10n,
                                  rule.applicationType,
                                ),
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
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _RuleFacts(rule: rule),
              ],
            );

            final actions = _RuleActions(
              rule: rule,
              canChange: canChange,
              canDelete: canDelete,
              onEdit: onEdit,
              onToggle: () => _toggleRule(context),
              onArchive: () => _confirmArchive(context),
            );

            if (constraints.maxWidth >= 720) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: content),
                  const SizedBox(width: 12),
                  actions,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                content,
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: actions,
                ),
              ],
            );
          },
        ),
      ),
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

class _RuleFacts extends StatelessWidget {
  const _RuleFacts({required this.rule});

  final DiscountRule rule;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final facts = [
      l10n.discountValueSummary(
        _valueTypeLabel(l10n, rule.valueType),
        _valueText(l10n, rule),
      ),
      l10n.discountPrioritySummary(rule.priority),
      if (rule.couponCode.isNotEmpty)
        l10n.discountCouponSummary(rule.couponCode),
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
      if (rule.productCategories.isNotEmpty)
        l10n.discountProductCategoryConstraintSummary(
          rule.productCategories.length,
        ),
      if (rule.customers.isNotEmpty)
        l10n.discountCustomerConstraintSummary(rule.customers.length),
      if (rule.suppliers.isNotEmpty)
        l10n.discountSupplierConstraintSummary(rule.suppliers.length),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final fact in facts)
          Text(fact, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
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
      DiscountValueType.fixedUnitAmount =>
        l10n.discountValueTypeFixedUnitAmount,
      DiscountValueType.fixedPrice => l10n.discountValueTypeFixedPrice,
    };
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(icon, size: 16),
      label: Text(label),
    );
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
