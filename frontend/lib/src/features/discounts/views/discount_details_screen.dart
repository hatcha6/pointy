import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/discount_rule.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/discount_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
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

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final rule = viewModel.rule;
        return AdaptiveMaxWidth(
          width: AppContentWidth.list,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _DiscountDetailsHeader(rule: rule),
              if (viewModel.hasLoadError) ...[
                const SizedBox(height: 12),
                PointyInlineMessage.error(
                  message: l10n.discountDetailsLoadError,
                ),
              ],
              if (viewModel.isLoading && viewModel.performance == null) ...[
                const SizedBox(height: 12),
                const PointyLoadingArea(),
              ],
              if (viewModel.performance case final performance?) ...[
                const SizedBox(height: 12),
                _PerformanceMetrics(performance: performance),
                const SizedBox(height: 12),
                _IncrementalitySection(
                  incrementality: performance.incrementality,
                ),
                const SizedBox(height: 12),
                _TrendSection(trend: performance.monthlyTrend),
                const SizedBox(height: 12),
                _ChannelBreakdownSection(
                  breakdown: performance.channelBreakdown,
                ),
              ],
              const SizedBox(height: 12),
              _ConfigurationSection(rule: rule),
              const SizedBox(height: 12),
              _ConstraintsSection(rule: rule),
              const SizedBox(height: 12),
              _BeneficiariesSection(viewModel: viewModel),
            ],
          ),
        );
      },
    );
  }
}

class _DiscountDetailsHeader extends StatelessWidget {
  const _DiscountDetailsHeader({required this.rule});

  final DiscountRule rule;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final facts = [
      if (rule.description.isNotEmpty) rule.description,
      ...discountRuleFacts(l10n, rule),
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.primary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  rule.applicationType == DiscountApplicationType.couponCode
                      ? Icons.confirmation_number_outlined
                      : Icons.auto_awesome_outlined,
                  color: colorScheme.onPrimary,
                  size: 34,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    rule.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: colorScheme.onPrimary,
                    ),
                  ),
                ),
              ],
            ),
            if (facts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                facts.join(' • '),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: colorScheme.onPrimary),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                PointyStatusPill(
                  label: rule.isActive
                      ? l10n.discountStatusActive
                      : l10n.discountStatusInactive,
                  icon: rule.isActive
                      ? Icons.check_circle_outline
                      : Icons.pause_circle_outline,
                ),
                PointyStatusPill(
                  label: discountChannelLabel(l10n, rule.channel),
                  icon: Icons.compare_arrows_outlined,
                ),
                PointyStatusPill(
                  label: discountApplicationLabel(l10n, rule.applicationType),
                  icon: Icons.rule_folder_outlined,
                ),
                if (rule.isArchived)
                  PointyStatusPill(
                    label: l10n.discountArchivedLabel,
                    icon: Icons.archive_outlined,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PerformanceMetrics extends StatelessWidget {
  const _PerformanceMetrics({required this.performance});

  final DiscountRulePerformance performance;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = performance.summary;
    final incrementality = performance.incrementality;
    return PointyDetailSection(
      title: l10n.discountDetailsPerformanceSection,
      icon: Icons.insights_outlined,
      child: PointyMetricGrid(
        maxColumns: 4,
        minTileWidth: 180,
        gap: PointyMetricGridGap.compact,
        metrics: [
          PointyMetricGridItem(
            label: l10n.discountDetailsRedemptionsMetric,
            value: summary.redemptionCount.toString(),
            icon: Icons.redeem_outlined,
            subtitle: l10n.discountDetailsApplicationsSubtitle(
              summary.applicationCount,
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
            label: l10n.discountDetailsNetInfluencedMetric,
            value: formatMoney(summary.influencedNet),
            icon: Icons.payments_outlined,
          ),
          PointyMetricGridItem(
            label: l10n.discountDetailsDiscountCostMetric,
            value: formatMoney(summary.discountAmount),
            icon: Icons.price_change_outlined,
            subtitle: l10n.discountDetailsDiscountRateSubtitle(
              l10n.discountPercentageValue(
                summary.discountRatePercent.toStringAsFixed(2),
              ),
            ),
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
            label: l10n.discountDetailsIncrementalNetMetric,
            value: formatMoney(incrementality.estimatedIncrementalNetValue),
            icon: Icons.add_chart_outlined,
            subtitle: incrementality.liftPercent == null
                ? l10n.discountDetailsLiftUnavailable
                : l10n.discountDetailsLiftSubtitle(
                    l10n.discountPercentageValue(
                      incrementality.liftPercent!.toStringAsFixed(2),
                    ),
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

class _IncrementalitySection extends StatelessWidget {
  const _IncrementalitySection({required this.incrementality});

  final DiscountIncrementality incrementality;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailSection(
      title: l10n.discountDetailsImpactSection,
      icon: Icons.query_stats_outlined,
      child: Column(
        children: [
          PointyInlineMessage(
            message: l10n.discountDetailsImpactMethodNote,
            icon: Icons.functions_outlined,
          ),
          const SizedBox(height: 12),
          PointyDetailRow(
            label: l10n.discountDetailsExpectedDocumentsLabel,
            value: incrementality.expectedDocumentsWithoutDiscount
                .toStringAsFixed(2),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountDetailsExpectedGrossLabel,
            value: formatMoney(incrementality.expectedGrossWithoutDiscount),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountDetailsIncrementalDocumentsLabel,
            value: incrementality.incrementalDocuments.toStringAsFixed(2),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountDetailsIncrementalGrossLabel,
            value: formatMoney(incrementality.incrementalGross),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountDetailsBaselinePeriodLabel,
            value: _periodValue(
              context,
              incrementality.baselinePeriodStart,
              incrementality.baselinePeriodEnd,
            ),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountDetailsBaselineDocumentsLabel,
            value: l10n.discountDetailsBaselineDocumentsValue(
              incrementality.baselineDocumentCount,
              formatMoney(incrementality.baselineGross),
            ),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountDetailsConfidenceLabel,
            value: _confidenceLabel(l10n, incrementality.confidence),
          ),
        ],
      ),
    );
  }
}

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
          ? Text(l10n.discountDetailsTrendEmpty)
          : _TrendRows(trend: trend),
    );
  }
}

class _TrendRows extends StatelessWidget {
  const _TrendRows({required this.trend});

  final List<DiscountTrendPoint> trend;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final maxGross = trend.fold<double>(
      0,
      (value, point) =>
          point.influencedGross > value ? point.influencedGross : value,
    );

    return Column(
      children: [
        for (final point in trend) ...[
          _TrendRow(point: point, maxGross: maxGross),
          if (point != trend.last) const Divider(height: 20),
        ],
        const SizedBox(height: 4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            l10n.discountDetailsTrendGrossHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _TrendRow extends StatelessWidget {
  const _TrendRow({required this.point, required this.maxGross});

  final DiscountTrendPoint point;
  final double maxGross;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final progress = maxGross <= 0 ? 0.0 : point.influencedGross / maxGross;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                point.period,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            Text(
              l10n.discountDetailsTrendValue(
                point.redemptionCount,
                formatMoney(point.influencedGross),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: progress.clamp(0, 1).toDouble()),
      ],
    );
  }
}

class _ChannelBreakdownSection extends StatelessWidget {
  const _ChannelBreakdownSection({required this.breakdown});

  final List<DiscountChannelPerformance> breakdown;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailSection(
      title: l10n.discountDetailsChannelBreakdownSection,
      icon: Icons.compare_arrows_outlined,
      child: breakdown.isEmpty
          ? Text(l10n.discountDetailsChannelBreakdownEmpty)
          : Column(
              children: [
                for (final channel in breakdown) ...[
                  PointyDetailRow(
                    label: discountChannelLabel(l10n, channel.channel),
                    value: l10n.discountDetailsChannelBreakdownValue(
                      channel.redemptionCount,
                      channel.documentCount,
                      formatMoney(channel.influencedNet),
                    ),
                  ),
                  if (channel != breakdown.last) const Divider(height: 20),
                ],
              ],
            ),
    );
  }
}

class _ConfigurationSection extends StatelessWidget {
  const _ConfigurationSection({required this.rule});

  final DiscountRule rule;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailSection(
      title: l10n.discountDetailsConfigurationSection,
      icon: Icons.tune_outlined,
      child: Column(
        children: [
          PointyDetailRow(
            label: l10n.discountStatusFilterLabel,
            value: rule.isActive
                ? l10n.discountStatusActive
                : l10n.discountStatusInactive,
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountChannelLabel,
            value: discountChannelLabel(l10n, rule.channel),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountApplicationTypeLabel,
            value: discountApplicationLabel(l10n, rule.applicationType),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountScopeLabel,
            value: discountScopeLabel(l10n, rule.scope),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountValueTypeLabel,
            value: l10n.discountValueSummary(
              discountValueTypeLabel(l10n, rule.valueType),
              discountValueText(l10n, rule),
            ),
          ),
          if (rule.couponCode.isNotEmpty) ...[
            const Divider(height: 20),
            PointyDetailRow(
              label: l10n.discountCouponCodeLabel,
              value: rule.couponCode,
            ),
          ],
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountPriorityLabel,
            value: rule.priority.toString(),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountExclusiveLabel,
            value: rule.exclusive ? l10n.yesLabel : l10n.noLabel,
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountStartsAtLabel,
            value: rule.startsAt == null
                ? l10n.discountNoDateSelected
                : formatDateTime(rule.startsAt!),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountEndsAtLabel,
            value: rule.endsAt == null
                ? l10n.discountNoDateSelected
                : formatDateTime(rule.endsAt!),
          ),
        ],
      ),
    );
  }
}

class _ConstraintsSection extends StatelessWidget {
  const _ConstraintsSection({required this.rule});

  final DiscountRule rule;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailSection(
      title: l10n.discountDetailsConstraintsSection,
      icon: Icons.rule_outlined,
      child: Column(
        children: [
          PointyDetailRow(
            label: l10n.discountMinSubtotalLabel,
            value: rule.minOrderSubtotal <= 0
                ? l10n.discountNoConstraintsSelected
                : formatMoney(rule.minOrderSubtotal),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountMinLineQuantityLabel,
            value:
                rule.minLineQuantity?.toString() ??
                l10n.discountNoConstraintsSelected,
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountMaxAmountLabel,
            value: rule.maxDiscountAmount == null
                ? l10n.discountNoConstraintsSelected
                : formatMoney(rule.maxDiscountAmount!),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountProductIdsLabel,
            value: _countOrAll(l10n, rule.products.length),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountVariantIdsLabel,
            value: _countOrAll(l10n, rule.variants.length),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountProductCategoryIdsLabel,
            value: _countOrAll(l10n, rule.productCategories.length),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountCustomerIdsLabel,
            value: _countOrAll(l10n, rule.customers.length),
          ),
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.discountSupplierIdsLabel,
            value: _countOrAll(l10n, rule.suppliers.length),
          ),
        ],
      ),
    );
  }
}

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
    return visibleRows.toDouble() * 96.0;
  }
}

class _BeneficiaryTile extends StatelessWidget {
  const _BeneficiaryTile({required this.beneficiary});

  final DiscountBeneficiary beneficiary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final facts = [
      l10n.discountDetailsUseCountValue(beneficiary.redemptionCount),
      l10n.discountDetailsDocumentCountValue(beneficiary.documentCount),
      l10n.discountDetailsBeneficiaryDiscountSummary(
        formatMoney(beneficiary.discountAmount),
      ),
      l10n.discountDetailsBeneficiaryGrossSummary(
        formatMoney(beneficiary.influencedGross),
      ),
      if (beneficiary.lastRedeemedAt != null)
        l10n.discountDetailsLastUsedSummary(
          formatDateTime(beneficiary.lastRedeemedAt!),
        ),
    ];

    return PointyDataRow(
      leading: CircleAvatar(
        child: Icon(_beneficiaryIcon(beneficiary.partyType)),
      ),
      title: _beneficiaryName(l10n, beneficiary),
      subtitle: facts.join(' • '),
      badges: [
        PointyStatusPill(
          label: _beneficiaryTypeLabel(l10n, beneficiary.partyType),
          icon: _beneficiaryIcon(beneficiary.partyType),
        ),
        PointyStatusPill(
          label: discountChannelLabel(l10n, beneficiary.channel),
          icon: Icons.compare_arrows_outlined,
        ),
      ],
      trailing: Text(formatMoney(beneficiary.influencedNet)),
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

String _beneficiaryTypeLabel(AppLocalizations l10n, String partyType) {
  return switch (partyType) {
    'customer' => l10n.discountCustomerPickerTitle,
    'supplier' => l10n.discountSupplierPickerTitle,
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

String _countOrAll(AppLocalizations l10n, int count) {
  return count == 0
      ? l10n.discountNoConstraintsSelected
      : l10n.discountDetailsCountValue(count);
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
