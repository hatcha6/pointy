import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/discount_rule.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/discount_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/discount_details_view_model.dart';
import '../view_models/discount_management_view_model.dart';
import 'discount_rule_form.dart';
import 'discount_rule_presenter.dart';

class DiscountDetailsScreen extends StatefulWidget {
  const DiscountDetailsScreen({
    super.key,
    required this.initialRule,
    required this.discountRepository,
    required this.managementViewModel,
    required this.catalogRepository,
    required this.contactRepository,
    required this.capabilities,
  });

  final DiscountRule initialRule;
  final DiscountRepository discountRepository;
  final DiscountManagementViewModel managementViewModel;
  final CatalogRepository catalogRepository;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;

  @override
  State<DiscountDetailsScreen> createState() => _DiscountDetailsScreenState();
}

class _DiscountDetailsScreenState extends State<DiscountDetailsScreen> {
  late final DiscountDetailsViewModel _viewModel = DiscountDetailsViewModel(
    discountRepository: widget.discountRepository,
    initialRule: widget.initialRule,
  );

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final rule = _viewModel.rule;
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.discountDetailsTitle(rule.name)),
            actions: [
              IconButton(
                tooltip: l10n.discountDetailsRefreshTooltip,
                onPressed: _viewModel.isLoading ? null : _viewModel.load,
                icon: const Icon(Icons.sync),
              ),
              if (widget.capabilities.canChangeDiscountRule)
                IconButton(
                  tooltip: l10n.discountEditTooltip,
                  onPressed: widget.managementViewModel.isSaving
                      ? null
                      : () => _openForm(context, rule),
                  icon: const Icon(Icons.edit_outlined),
                ),
            ],
          ),
          body: SafeArea(child: DiscountDetailsView(viewModel: _viewModel)),
        );
      },
    );
  }

  Future<void> _openForm(BuildContext context, DiscountRule rule) async {
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
            viewModel: widget.managementViewModel,
            catalogRepository: widget.catalogRepository,
            contactRepository: widget.contactRepository,
            rule: rule,
            onSaved: () => Navigator.of(sheetContext).pop(),
          ),
        );
      },
    );
    await _viewModel.load();
  }
}

/// Embeddable discount details body: used by [DiscountDetailsScreen] as a
/// pushed route on compact widths, and by the discount management
/// master-detail pane on desktop.
class DiscountDetailsView extends StatelessWidget {
  const DiscountDetailsView({super.key, required this.viewModel});

  final DiscountDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final rule = viewModel.rule;
        return AdaptiveMaxWidth(
          width: AppContentWidth.list,
          child: ListView(
            padding: EdgeInsets.all(spacing.lg),
            children: [
              _DiscountHero(rule: rule),
              if (viewModel.hasLoadError) ...[
                SizedBox(height: spacing.md),
                PointyInlineMessage.error(
                  message: l10n.discountDetailsLoadError,
                ),
              ],
              if (viewModel.isLoading && viewModel.performance == null) ...[
                SizedBox(height: spacing.md),
                const PointyLoadingArea(),
              ],
              if (viewModel.performance case final performance?) ...[
                SizedBox(height: spacing.md),
                _PerformanceMetrics(performance: performance),
                SizedBox(height: spacing.md),
                _ImpactSection(incrementality: performance.incrementality),
                SizedBox(height: spacing.md),
                _TrendSection(trend: performance.monthlyTrend),
                if (performance.channelBreakdown.isNotEmpty) ...[
                  SizedBox(height: spacing.md),
                  _ChannelBreakdownSection(
                    breakdown: performance.channelBreakdown,
                  ),
                ],
              ],
              SizedBox(height: spacing.md),
              _HowItWorksSection(rule: rule),
              SizedBox(height: spacing.md),
              _AppliesToSection(rule: rule),
              SizedBox(height: spacing.md),
              _BeneficiariesSection(viewModel: viewModel),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Hero
// ---------------------------------------------------------------------------

class _DiscountHero extends StatelessWidget {
  const _DiscountHero({required this.rule});

  final DiscountRule rule;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isCoupon = rule.applicationType == DiscountApplicationType.couponCode;

    return PointyDetailHero(
      icon: isCoupon
          ? Icons.confirmation_number_outlined
          : Icons.auto_awesome_outlined,
      title: rule.name,
      value: discountValueText(l10n, rule),
      valueSubtitle:
          '${discountValueTypeLabel(l10n, rule.valueType)} · '
          '${discountScopeLabel(l10n, rule.scope)}',
      description: rule.description,
      pills: [
        PointyHeroPill(
          label: rule.isActive
              ? l10n.discountStatusActive
              : l10n.discountStatusInactive,
          icon: rule.isActive
              ? Icons.check_circle_outline
              : Icons.pause_circle_outline,
        ),
        PointyHeroPill(
          label: discountChannelLabel(l10n, rule.channel),
          icon: Icons.compare_arrows_outlined,
        ),
        PointyHeroPill(
          label: rule.couponCode.isNotEmpty
              ? rule.couponCode
              : discountApplicationLabel(l10n, rule.applicationType),
          icon: isCoupon
              ? Icons.confirmation_number_outlined
              : Icons.bolt_outlined,
        ),
        if (rule.isArchived)
          PointyHeroPill(
            label: l10n.discountArchivedLabel,
            icon: Icons.archive_outlined,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Performance KPIs (already card-based)
// ---------------------------------------------------------------------------

class _PerformanceMetrics extends StatelessWidget {
  const _PerformanceMetrics({required this.performance});

  final DiscountRulePerformance performance;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final summary = performance.summary;
    final incrementality = performance.incrementality;
    return PointyDetailSection(
      title: l10n.discountDetailsPerformanceSection,
      icon: Icons.insights_outlined,
      child: PointyMetricGrid(
        maxColumns: 4,
        minTileWidth: 170,
        gap: PointyMetricGridGap.compact,
        metrics: [
          PointyMetricGridItem(
            label: l10n.discountDetailsRedemptionsMetric,
            value: summary.redemptionCount.toString(),
            icon: Icons.redeem_outlined,
            accentColor: colors.primaryStrong,
            subtitle: l10n.discountDetailsApplicationsSubtitle(
              summary.applicationCount,
            ),
          ),
          PointyMetricGridItem(
            label: l10n.discountDetailsDiscountCostMetric,
            value: formatMoney(summary.discountAmount),
            icon: Icons.price_change_outlined,
            accentColor: colors.warning,
            subtitle: l10n.discountDetailsDiscountRateSubtitle(
              l10n.discountPercentageValue(
                summary.discountRatePercent.toStringAsFixed(2),
              ),
            ),
          ),
          PointyMetricGridItem(
            label: l10n.discountDetailsNetInfluencedMetric,
            value: formatMoney(summary.influencedNet),
            icon: Icons.payments_outlined,
            accentColor: colors.success,
          ),
          PointyMetricGridItem(
            label: l10n.discountDetailsIncrementalNetMetric,
            value: formatMoney(incrementality.estimatedIncrementalNetValue),
            icon: Icons.add_chart_outlined,
            accentColor: colors.success,
            subtitle: incrementality.liftPercent == null
                ? l10n.discountDetailsLiftUnavailable
                : l10n.discountDetailsLiftSubtitle(
                    l10n.discountPercentageValue(
                      incrementality.liftPercent!.toStringAsFixed(2),
                    ),
                  ),
          ),
          PointyMetricGridItem(
            label: l10n.discountDetailsBeneficiariesMetric,
            value: summary.beneficiaryCount.toString(),
            icon: Icons.groups_outlined,
            subtitle: l10n.discountDetailsBeneficiariesSubtitle(
              summary.uniqueCustomerCount,
              summary.uniqueSupplierCount,
            ),
          ),
          PointyMetricGridItem(
            label: l10n.discountDetailsGrossInfluencedMetric,
            value: formatMoney(summary.influencedGross),
            icon: Icons.trending_up_outlined,
          ),
          PointyMetricGridItem(
            label: l10n.discountDetailsAverageDocumentMetric,
            value: formatMoney(summary.averageDocumentValue),
            icon: Icons.receipt_long_outlined,
            subtitle: l10n.discountDetailsAverageDiscountSubtitle(
              formatMoney(summary.averageDiscountAmount),
            ),
          ),
          PointyMetricGridItem(
            label: l10n.discountDetailsUsageLimitMetric,
            value: summary.usageLimit == null
                ? l10n.discountDetailsUnlimitedUsage
                : l10n.discountUsageSummary(
                    summary.redemptionCount,
                    summary.usageLimit!,
                  ),
            icon: Icons.speed_outlined,
            subtitle: summary.remainingUsage == null
                ? l10n.discountDetailsNoUsageLimit
                : l10n.discountDetailsUsageRemaining(
                    summary.remainingUsage!,
                    summary.usageLimit!,
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Estimated impact (incrementality)
// ---------------------------------------------------------------------------

class _ImpactSection extends StatelessWidget {
  const _ImpactSection({required this.incrementality});

  final DiscountIncrementality incrementality;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    return PointyDetailSection(
      title: l10n.discountDetailsImpactSection,
      icon: Icons.query_stats_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ImpactCallout(incrementality: incrementality),
          SizedBox(height: spacing.md),
          PointyMetricGrid(
            maxColumns: 4,
            minTileWidth: 160,
            gap: PointyMetricGridGap.compact,
            metrics: [
              PointyMetricGridItem(
                label: l10n.discountDetailsExpectedGrossLabel,
                value: formatMoney(incrementality.expectedGrossWithoutDiscount),
                icon: Icons.timeline_outlined,
              ),
              PointyMetricGridItem(
                label: l10n.discountDetailsIncrementalGrossLabel,
                value: formatMoney(incrementality.incrementalGross),
                icon: Icons.trending_up_outlined,
                accentColor: context.pointyColors.success,
              ),
              PointyMetricGridItem(
                label: l10n.discountDetailsIncrementalDocumentsLabel,
                value: incrementality.incrementalDocuments.toStringAsFixed(1),
                icon: Icons.receipt_long_outlined,
              ),
              PointyMetricGridItem(
                label: l10n.discountDetailsBaselinePeriodLabel,
                value: _periodValue(
                  context,
                  incrementality.baselinePeriodStart,
                  incrementality.baselinePeriodEnd,
                ),
                icon: Icons.history_outlined,
                subtitle: l10n.discountDetailsBaselineDocumentsValue(
                  incrementality.baselineDocumentCount,
                  formatMoney(incrementality.baselineGross),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ImpactCallout extends StatelessWidget {
  const _ImpactCallout({required this.incrementality});

  final DiscountIncrementality incrementality;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final lift = incrementality.liftPercent;
    final headline = lift == null
        ? l10n.discountDetailsLiftUnavailable
        : l10n.discountDetailsLiftSubtitle(
            l10n.discountPercentageValue(lift.toStringAsFixed(2)),
          );

    return PointyDetailCallout(
      icon: Icons.insights_outlined,
      title: headline,
      message: l10n.discountDetailsImpactMethodNote,
      trailing: PointyStatusPill(
        label: _confidenceLabel(l10n, incrementality.confidence),
        icon: Icons.verified_outlined,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Monthly trend
// ---------------------------------------------------------------------------

class _TrendSection extends StatelessWidget {
  const _TrendSection({required this.trend});

  final List<DiscountTrendPoint> trend;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailSection(
      title: l10n.discountDetailsTrendSection,
      icon: Icons.show_chart_outlined,
      child: trend.isEmpty
          ? PointyEmptyState(
              icon: Icons.show_chart_outlined,
              title: l10n.discountDetailsTrendEmpty,
            )
          : _TrendBars(trend: trend),
    );
  }
}

class _TrendBars extends StatelessWidget {
  const _TrendBars({required this.trend});

  final List<DiscountTrendPoint> trend;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final maxGross = trend.fold<double>(
      0,
      (value, point) =>
          point.influencedGross > value ? point.influencedGross : value,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < trend.length; i++) ...[
          if (i > 0) SizedBox(height: spacing.md),
          _TrendBar(point: trend[i], maxGross: maxGross),
        ],
        SizedBox(height: spacing.sm),
        Row(
          children: [
            Icon(Icons.info_outline, size: 14, color: colors.mutedInk),
            const SizedBox(width: 4),
            Text(
              l10n.discountDetailsTrendGrossHint,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ],
        ),
      ],
    );
  }
}

class _TrendBar extends StatelessWidget {
  const _TrendBar({required this.point, required this.maxGross});

  final DiscountTrendPoint point;
  final double maxGross;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final progress = maxGross <= 0
        ? 0.0
        : (point.influencedGross / maxGross).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                point.period,
                style: textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              l10n.discountDetailsTrendValue(
                point.redemptionCount,
                formatMoney(point.influencedGross),
              ),
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 10,
            color: colors.surfaceSunken,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FractionallySizedBox(
                widthFactor: progress == 0 ? 0.02 : progress,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: PointyColors.primary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Channel breakdown
// ---------------------------------------------------------------------------

class _ChannelBreakdownSection extends StatelessWidget {
  const _ChannelBreakdownSection({required this.breakdown});

  final List<DiscountChannelPerformance> breakdown;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailSection(
      title: l10n.discountDetailsChannelBreakdownSection,
      icon: Icons.compare_arrows_outlined,
      child: ResponsiveFormGrid(
        minChildWidth: 240,
        maxColumns: 2,
        children: [
          for (final channel in breakdown) _ChannelCard(channel: channel),
        ],
      ),
    );
  }
}

class _ChannelCard extends StatelessWidget {
  const _ChannelCard({required this.channel});

  final DiscountChannelPerformance channel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        border: Border.all(color: colors.line),
      ),
      padding: EdgeInsets.all(spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.compare_arrows_outlined,
                size: 18,
                color: colors.primaryStrong,
              ),
              const SizedBox(width: 6),
              Text(
                discountChannelLabel(l10n, channel.channel),
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.sm),
          Text(
            formatMoney(channel.influencedNet),
            style: textTheme.titleMedium?.copyWith(
              color: colors.success,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            l10n.discountDetailsChannelBreakdownValue(
              channel.redemptionCount,
              channel.documentCount,
              formatMoney(channel.influencedNet),
            ),
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// How it works (configuration)
// ---------------------------------------------------------------------------

class _HowItWorksSection extends StatelessWidget {
  const _HowItWorksSection({required this.rule});

  final DiscountRule rule;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailSection(
      title: l10n.discountDetailsConfigurationSection,
      icon: Icons.tune_outlined,
      child: PointyMetricGrid(
        maxColumns: 3,
        minTileWidth: 160,
        gap: PointyMetricGridGap.compact,
        metrics: [
          PointyMetricGridItem(
            label: l10n.discountChannelLabel,
            value: discountChannelLabel(l10n, rule.channel),
            icon: Icons.compare_arrows_outlined,
          ),
          PointyMetricGridItem(
            label: l10n.discountApplicationTypeLabel,
            value: discountApplicationLabel(l10n, rule.applicationType),
            icon: Icons.bolt_outlined,
            subtitle: rule.couponCode.isNotEmpty ? rule.couponCode : null,
          ),
          PointyMetricGridItem(
            label: l10n.discountScopeLabel,
            value: discountScopeLabel(l10n, rule.scope),
            icon: Icons.view_list_outlined,
          ),
          PointyMetricGridItem(
            label: l10n.discountPriorityLabel,
            value: rule.priority.toString(),
            icon: Icons.low_priority_outlined,
            subtitle: rule.exclusive ? l10n.discountExclusiveShort : null,
          ),
          PointyMetricGridItem(
            label: l10n.discountStartsAtLabel,
            value: rule.startsAt == null
                ? l10n.discountNoDateSelected
                : formatDate(rule.startsAt!),
            icon: Icons.play_circle_outline,
          ),
          PointyMetricGridItem(
            label: l10n.discountEndsAtLabel,
            value: rule.endsAt == null
                ? l10n.discountNoDateSelected
                : formatDate(rule.endsAt!),
            icon: Icons.event_busy_outlined,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Applies to (constraints)
// ---------------------------------------------------------------------------

class _AppliesToSection extends StatelessWidget {
  const _AppliesToSection({required this.rule});

  final DiscountRule rule;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    final targetingChips = <Widget>[
      if (rule.productCategories.isNotEmpty)
        _TargetChip(
          icon: Icons.category_outlined,
          label: l10n.discountProductCategoryConstraintSummary(
            rule.productCategories.length,
          ),
        ),
      if (rule.products.isNotEmpty)
        _TargetChip(
          icon: Icons.inventory_2_outlined,
          label: l10n.discountProductConstraintSummary(rule.products.length),
        ),
      if (rule.variants.isNotEmpty)
        _TargetChip(
          icon: Icons.style_outlined,
          label: l10n.discountVariantConstraintSummary(rule.variants.length),
        ),
      if (rule.customers.isNotEmpty)
        _TargetChip(
          icon: Icons.person_outline,
          label: l10n.discountCustomerConstraintSummary(rule.customers.length),
        ),
      if (rule.suppliers.isNotEmpty)
        _TargetChip(
          icon: Icons.local_shipping_outlined,
          label: l10n.discountSupplierConstraintSummary(rule.suppliers.length),
        ),
    ];

    final conditions = <PointyMetricGridItem>[
      if (rule.minOrderSubtotal > 0)
        PointyMetricGridItem(
          label: l10n.discountMinSubtotalLabel,
          value: formatMoney(rule.minOrderSubtotal),
          icon: Icons.shopping_cart_outlined,
        ),
      if (rule.minLineQuantity != null)
        PointyMetricGridItem(
          label: l10n.discountMinLineQuantityLabel,
          value: rule.minLineQuantity!.toString(),
          icon: Icons.numbers_outlined,
        ),
      if (rule.maxDiscountAmount != null)
        PointyMetricGridItem(
          label: l10n.discountMaxAmountLabel,
          value: formatMoney(rule.maxDiscountAmount!),
          icon: Icons.production_quantity_limits_outlined,
        ),
    ];

    return PointyDetailSection(
      title: l10n.discountDetailsConstraintsSection,
      icon: Icons.adjust_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (targetingChips.isEmpty)
            Row(
              children: [
                Icon(
                  Icons.all_inclusive_outlined,
                  size: 18,
                  color: colors.primaryStrong,
                ),
                SizedBox(width: spacing.xs),
                Text(
                  l10n.discountSummaryAppliesAll,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            )
          else
            Wrap(
              spacing: spacing.xs,
              runSpacing: spacing.xs,
              children: targetingChips,
            ),
          if (conditions.isNotEmpty) ...[
            SizedBox(height: spacing.md),
            PointyMetricGrid(
              maxColumns: 3,
              minTileWidth: 160,
              gap: PointyMetricGridGap.compact,
              metrics: conditions,
            ),
          ],
        ],
      ),
    );
  }
}

class _TargetChip extends StatelessWidget {
  const _TargetChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return PointyStatusPill(label: label, icon: icon, compact: false);
  }
}

// ---------------------------------------------------------------------------
// Beneficiaries
// ---------------------------------------------------------------------------

class _BeneficiariesSection extends StatelessWidget {
  const _BeneficiariesSection({required this.viewModel});

  final DiscountDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailSection(
      title: l10n.discountDetailsBeneficiariesSection,
      icon: Icons.people_alt_outlined,
      child: SizedBox(
        height: _beneficiaryListHeight(
          viewModel.beneficiaries.length,
          viewModel.hasMoreBeneficiaries,
        ),
        child: PointyDataList<DiscountBeneficiary>(
          items: viewModel.beneficiaries,
          onLoadMore: viewModel.loadMoreBeneficiaries,
          hasMore: viewModel.hasMoreBeneficiaries,
          isLoadingInitial: viewModel.isLoadingBeneficiaries,
          isLoadingMore: viewModel.isLoadingMoreBeneficiaries,
          hasError: viewModel.hasBeneficiaryLoadError,
          framed: false,
          padding: EdgeInsets.zero,
          emptyBuilder: (context) => PointyEmptyState(
            icon: Icons.people_alt_outlined,
            title: l10n.discountDetailsBeneficiariesEmpty,
          ),
          errorBuilder: (context) => PointyErrorState(
            title: l10n.discountDetailsBeneficiariesLoadError,
            icon: Icons.people_alt_outlined,
          ),
          itemBuilder: (context, beneficiary) {
            return _BeneficiaryTile(beneficiary: beneficiary);
          },
        ),
      ),
    );
  }

  double _beneficiaryListHeight(int itemCount, bool hasMore) {
    if (itemCount == 0) {
      return 220;
    }
    final visibleRows = (itemCount + (hasMore ? 1 : 0)).clamp(1, 5);
    return visibleRows.toDouble() * 88.0;
  }
}

class _BeneficiaryTile extends StatelessWidget {
  const _BeneficiaryTile({required this.beneficiary});

  final DiscountBeneficiary beneficiary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final facts = [
      l10n.discountDetailsUseCountValue(beneficiary.redemptionCount),
      l10n.discountDetailsBeneficiaryDiscountSummary(
        formatMoney(beneficiary.discountAmount),
      ),
      if (beneficiary.lastRedeemedAt != null)
        l10n.discountDetailsLastUsedSummary(
          formatDateTime(beneficiary.lastRedeemedAt!),
        ),
    ];

    return PointyDataRow(
      leading: CircleAvatar(
        backgroundColor: PointyColors.primaryContainer,
        foregroundColor: colors.primaryStrong,
        child: Icon(_beneficiaryIcon(beneficiary.partyType)),
      ),
      title: _beneficiaryName(l10n, beneficiary),
      subtitle: facts.join(' · '),
      badges: [
        PointyStatusPill(
          label: discountChannelLabel(l10n, beneficiary.channel),
          icon: Icons.compare_arrows_outlined,
          color: colors.mutedInk,
        ),
      ],
      trailing: Text(
        formatMoney(beneficiary.influencedNet),
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: colors.success,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

String _beneficiaryName(
  AppLocalizations l10n,
  DiscountBeneficiary beneficiary,
) {
  if (beneficiary.name.trim().isNotEmpty) {
    return beneficiary.name;
  }
  return switch (beneficiary.partyType) {
    'unknown_supplier' => l10n.discountDetailsUnknownSupplier,
    _ => l10n.discountDetailsWalkInCustomer,
  };
}

IconData _beneficiaryIcon(String partyType) {
  return switch (partyType) {
    'supplier' || 'unknown_supplier' => Icons.local_shipping_outlined,
    _ => Icons.person_outline,
  };
}

String _periodValue(BuildContext context, DateTime? start, DateTime? end) {
  final l10n = AppLocalizations.of(context)!;
  if (start == null || end == null) {
    return l10n.customerEmptyValue;
  }
  return l10n.discountDetailsPeriodValue(formatDate(start), formatDate(end));
}

String _confidenceLabel(AppLocalizations l10n, String confidence) {
  return switch (confidence) {
    'high' => l10n.discountDetailsConfidenceHigh,
    'medium' => l10n.discountDetailsConfidenceMedium,
    'low' => l10n.discountDetailsConfidenceLow,
    _ => l10n.discountDetailsConfidenceInsufficient,
  };
}
