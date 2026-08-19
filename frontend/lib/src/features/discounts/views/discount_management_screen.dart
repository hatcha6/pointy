import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/discount_rule.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/query_controls/query_empty_state.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/discount_details_view_model.dart';
import '../view_models/discount_management_view_model.dart';
import 'discount_details_screen.dart';
import 'discount_rule_query_controls.dart';
import 'discount_rule_form.dart';
import 'discount_rule_presenter.dart';

class DiscountManagementScreen extends StatefulWidget {
  const DiscountManagementScreen({
    super.key,
    required this.viewModel,
    required this.catalogRepository,
    required this.contactRepository,
    required this.capabilities,
    required this.navigation,
  });

  final DiscountManagementViewModel viewModel;
  final CatalogRepository catalogRepository;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;

  @override
  State<DiscountManagementScreen> createState() =>
      _DiscountManagementScreenState();
}

class _DiscountManagementScreenState extends State<DiscountManagementScreen> {
  DiscountManagementViewModel get viewModel => widget.viewModel;
  CatalogRepository get catalogRepository => widget.catalogRepository;
  ContactRepository get contactRepository => widget.contactRepository;
  AuthorizationCapabilities get capabilities => widget.capabilities;

  DiscountRule? _selectedRule;
  DiscountDetailsViewModel? _selectedRuleViewModel;

  void _selectRule(DiscountRule rule) {
    setState(() {
      _selectedRule = rule;
      _selectedRuleViewModel = DiscountDetailsViewModel(
        discountRepository: viewModel.discountRepository,
        initialRule: rule,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.discounts,
            navigation: widget.navigation,
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
            child: MasterDetailLayout(
              listPaneBuilder: (paneContext, isDualPane) =>
                  _DiscountManagementBody(
                    viewModel: viewModel,
                    capabilities: capabilities,
                    onCreateRule: viewModel.isSaving
                        ? null
                        : () => _showRuleForm(context),
                    onEditRule: (rule) => _showRuleForm(context, rule: rule),
                    onOpenDetails: isDualPane
                        ? _selectRule
                        : (rule) => _pushDetails(context, rule),
                  ),
              placeholder: PointyEmptyState(
                icon: Icons.local_offer_outlined,
                title: l10n.discountsSelectDiscountPlaceholder,
              ),
              detailPane: _selectedRule == null
                  ? null
                  : DiscountDetailsView(
                      key: ValueKey('discount_detail_${_selectedRule!.id}'),
                      viewModel: _selectedRuleViewModel!,
                    ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showRuleForm(BuildContext context, {DiscountRule? rule}) async {
    await showAdaptiveFormSurface<void>(
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
    if (rule != null && rule.id == _selectedRule?.id) {
      await _selectedRuleViewModel?.load();
    }
  }

  Future<void> _pushDetails(BuildContext context, DiscountRule rule) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscountDetailsScreen(
          initialRule: rule,
          discountRepository: viewModel.discountRepository,
          managementViewModel: viewModel,
          catalogRepository: catalogRepository,
          contactRepository: contactRepository,
          capabilities: capabilities,
        ),
      ),
    );
  }
}

class _DiscountManagementBody extends StatelessWidget {
  const _DiscountManagementBody({
    required this.viewModel,
    required this.capabilities,
    required this.onCreateRule,
    required this.onEditRule,
    required this.onOpenDetails,
  });

  final DiscountManagementViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final VoidCallback? onCreateRule;
  final ValueChanged<DiscountRule> onEditRule;
  final ValueChanged<DiscountRule> onOpenDetails;

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
                style: TextStyle(color: context.pointyColors.danger),
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
                action: FilledButton.tonalIcon(
                  onPressed: viewModel.loadRules,
                  icon: const Icon(Icons.sync),
                  label: Text(l10n.retryButton),
                ),
              ),
              emptyBuilder: (context) => QueryEmptyState(
                icon: Icons.local_offer_outlined,
                search: viewModel.query.search,
                hasFilters: viewModel.query.activeFilterCount > 0,
                emptyTitle: l10n.discountEmptyRules,
                onClear: () => viewModel.applyQuery(
                  DiscountRuleQueryControls.cleared(viewModel.query),
                ),
                emptyAction: capabilities.canCreateDiscountRule
                    ? FilledButton.icon(
                        onPressed: onCreateRule,
                        icon: const Icon(Icons.add),
                        label: Text(l10n.discountCreateButton),
                      )
                    : null,
              ),
              itemBuilder: (context, rule) {
                return _DiscountRuleTile(
                  rule: rule,
                  viewModel: viewModel,
                  capabilities: capabilities,
                  onEdit: () => onEditRule(rule),
                  onOpenDetails: () => onOpenDetails(rule),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DiscountRuleTile extends StatelessWidget {
  const _DiscountRuleTile({
    required this.rule,
    required this.viewModel,
    required this.capabilities,
    required this.onEdit,
    required this.onOpenDetails,
  });

  final DiscountRule rule;
  final DiscountManagementViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onEdit;
  final VoidCallback onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final canChange = capabilities.canChangeDiscountRule && !viewModel.isSaving;
    final canDelete = capabilities.canDeleteDiscountRule && !viewModel.isSaving;
    final targeted =
        rule.products.isNotEmpty ||
        rule.variants.isNotEmpty ||
        rule.productCategories.isNotEmpty ||
        rule.customers.isNotEmpty ||
        rule.suppliers.isNotEmpty;
    final subtitle = rule.description.trim().isNotEmpty
        ? rule.description.trim()
        : '${discountScopeLabel(l10n, rule.scope)} · '
              '${targeted ? l10n.discountTargetedShort : l10n.discountSummaryAppliesAll}';

    return PointyDataRow(
      onTap: onOpenDetails,
      leading: CircleAvatar(
        backgroundColor: rule.isActive
            ? colors.primaryContainer
            : colors.subtleFill,
        foregroundColor: rule.isActive ? colors.primaryStrong : colors.mutedInk,
        child: Icon(
          rule.applicationType == DiscountApplicationType.couponCode
              ? Icons.confirmation_number_outlined
              : Icons.auto_awesome_outlined,
        ),
      ),
      title: rule.name,
      subtitle: subtitle,
      badges: [
        PointyStatusPill(
          label: discountValueText(l10n, rule),
          icon: Icons.sell_outlined,
          color: colors.primaryStrong,
        ),
        PointyStatusPill(
          label: rule.isActive
              ? l10n.discountStatusActive
              : l10n.discountStatusInactive,
          icon: rule.isActive
              ? Icons.check_circle_outline
              : Icons.pause_circle_outline,
          color: rule.isActive ? colors.success : colors.mutedInk,
        ),
        PointyStatusPill(
          label: discountChannelLabel(l10n, rule.channel),
          icon: Icons.compare_arrows_outlined,
          color: colors.mutedInk,
        ),
        if (rule.couponCode.isNotEmpty)
          PointyStatusPill(
            label: rule.couponCode,
            icon: Icons.confirmation_number_outlined,
            color: colors.accentAmber,
          ),
        if (rule.isArchived)
          PointyStatusPill(
            label: l10n.discountArchivedLabel,
            icon: Icons.archive_outlined,
            color: colors.mutedInk,
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
