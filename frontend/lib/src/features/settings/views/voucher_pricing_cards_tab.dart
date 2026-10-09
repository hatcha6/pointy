import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/voucher_pricing.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../view_models/voucher_pricing_view_model.dart';

/// The cards tab: search, a brand filter, one row per card with its own price
/// field, and «اتباع سعر الشركة للكل».
class VoucherPricingCardsTab extends StatefulWidget {
  const VoucherPricingCardsTab({super.key, required this.viewModel});

  final VoucherPricingViewModel viewModel;

  @override
  State<VoucherPricingCardsTab> createState() => _VoucherPricingCardsTabState();
}

class _VoucherPricingCardsTabState extends State<VoucherPricingCardsTab> {
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearch(String text) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => widget.viewModel.loadCards(search: text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final vm = widget.viewModel;
    final rows = vm.rows;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: TextField(
                key: const ValueKey('pricing_card_search'),
                onChanged: _onSearch,
                decoration: InputDecoration(
                  hintText: l10n.voucherPricingSearchHint,
                  prefixIcon: const Icon(Icons.search_rounded),
                  isDense: true,
                ),
              ),
            ),
            if (vm.belowCostCount > 0) _BelowCostBanner(viewModel: vm),
            if (vm.brands.isNotEmpty)
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    _BrandChip(
                      label: l10n.voucherPricingAllBrands,
                      selected: vm.brand.isEmpty,
                      onTap: () => vm.loadCards(brand: ''),
                    ),
                    for (final brand in vm.brands)
                      _BrandChip(
                        label: brand,
                        selected: vm.brand == brand,
                        onTap: () => vm.loadCards(brand: brand),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.voucherPricingCardCount(vm.count),
                      style: textTheme.labelMedium?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    key: const ValueKey('pricing_follow_all'),
                    onPressed: rows.isEmpty || vm.isBulkBusy
                        ? null
                        : () async {
                            final ok = await vm.followCompany();
                            if (ok && context.mounted) {
                              ScaffoldMessenger.maybeOf(context)
                                ?..clearSnackBars()
                                ..showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      l10n.voucherPricingFollowAllDone,
                                    ),
                                  ),
                                );
                            }
                          },
                    icon: const Icon(Icons.undo_rounded, size: 18),
                    label: Text(l10n.voucherPricingFollowAll),
                  ),
                ],
              ),
            ),
            if (vm.cardError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: PointyInlineMessage.error(
                  key: const ValueKey('pricing_card_error'),
                  message: vm.cardError!.isEmpty
                      ? l10n.voucherPricingCardFailed
                      : vm.cardError!,
                  icon: Icons.error_outline_rounded,
                  compact: true,
                ),
              ),
            Expanded(child: _list(context, l10n, vm, rows)),
          ],
        ),
      ),
    );
  }

  Widget _list(
    BuildContext context,
    AppLocalizations l10n,
    VoucherPricingViewModel vm,
    List<CardPriceRow> rows,
  ) {
    if (rows.isEmpty) {
      if (vm.cardsLoading) {
        return const PointyLoadingArea();
      }
      if (vm.cardsFailed) {
        return PointyErrorState(
          title: l10n.voucherPricingLoadError,
          icon: Icons.cloud_off_outlined,
          action: FilledButton.icon(
            onPressed: vm.loadCards,
            icon: const Icon(Icons.sync),
            label: Text(l10n.retryButton),
          ),
        );
      }
      return PointyEmptyState(
        title: l10n.voucherPricingNoCards,
        icon: Icons.style_outlined,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: rows.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == rows.length) {
          return vm.hasMore || vm.cardsFailed
              ? Center(
                  child: vm.cardsLoading
                      ? const PointySpinner()
                      : OutlinedButton(
                          key: const ValueKey('pricing_load_more'),
                          onPressed: vm.loadMore,
                          child: Text(l10n.voucherPricingLoadMore),
                        ),
                )
              : const SizedBox.shrink();
        }
        final row = rows[index];
        return _CardRow(
          key: ValueKey(
            'pricing_card_${row.variantId}_${row.mode.name}'
            '_${row.customPrice}',
          ),
          row: row,
          viewModel: vm,
        );
      },
    );
  }
}

/// Cards the shop priced itself that the company's cost has overtaken: blocked
/// from sale until fixed. One tap shows them, one hands them back to the company.
class _BelowCostBanner extends StatelessWidget {
  const _BelowCostBanner({required this.viewModel});

  final VoucherPricingViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final vm = viewModel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Container(
        key: const ValueKey('pricing_below_cost_banner'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(PointyRadii.card),
          border: Border.all(color: colors.warning),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: colors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.voucherPricingBelowCostBannerTitle(vm.belowCostCount),
                    style: textTheme.titleSmall?.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l10n.voucherPricingBelowCostBannerBody,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton(
                  key: const ValueKey('pricing_below_cost_filter'),
                  onPressed: () =>
                      vm.loadCards(belowCostOnly: !vm.belowCostOnly),
                  child: Text(
                    vm.belowCostOnly
                        ? l10n.voucherPricingBelowCostShowAll
                        : l10n.voucherPricingBelowCostShowOnly,
                  ),
                ),
                FilledButton.icon(
                  key: const ValueKey('pricing_below_cost_use_company'),
                  onPressed: vm.isBulkBusy
                      ? null
                      : () async {
                          final ok = await vm.followCompanyForBelowCost();
                          if (ok && context.mounted) {
                            ScaffoldMessenger.maybeOf(context)
                              ?..clearSnackBars()
                              ..showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.voucherPricingUseCompanyPricingDone,
                                  ),
                                ),
                              );
                          }
                        },
                  icon: const Icon(Icons.undo_rounded, size: 18),
                  label: Text(l10n.voucherPricingUseCompanyPricing),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BrandChip extends StatelessWidget {
  const _BrandChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(end: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    ),
  );
}

class _CardRow extends StatefulWidget {
  const _CardRow({super.key, required this.row, required this.viewModel});

  final CardPriceRow row;
  final VoucherPricingViewModel viewModel;

  @override
  State<_CardRow> createState() => _CardRowState();
}

class _CardRowState extends State<_CardRow> {
  late final TextEditingController _controller = TextEditingController(
    text:
        widget.row.mode == PricingMode.custom && widget.row.customPrice != null
        ? widget.row.customPrice!.toStringAsFixed(2)
        : '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double? get _typed => double.tryParse(_controller.text.trim());

  Future<void> _save() async {
    final price = _typed;
    final vm = widget.viewModel;
    final ok = await vm.saveCardPrice(widget.row, price);
    if (ok && mounted) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.maybeOf(context)
        ?..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.voucherPricingCardSaved)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final row = widget.row;
    final busy = widget.viewModel.savingVariant == row.variantId;
    final custom = row.mode == PricingMode.custom;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: Border.all(color: row.belowCost ? colors.warning : colors.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (row.belowCost) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: PointyStatusPill(
                      key: ValueKey('pricing_card_below_cost_${row.variantId}'),
                      label: l10n.voucherPricingBelowCostBadge,
                      color: colors.warning,
                    ),
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  [
                    if (row.brand.isNotEmpty) row.brand,
                    if (row.shopPays != null)
                      '${l10n.voucherPricingShopPays} ${formatMoney(row.shopPays!)}',
                    if (row.companyPrice != null)
                      '${l10n.voucherPricingCompanyPrice} ${formatMoney(row.companyPrice!)}',
                  ].join(' · '),
                  style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 112,
            child: TextField(
              key: ValueKey('pricing_card_price_${row.variantId}'),
              controller: _controller,
              enabled: !busy,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                isDense: true,
                labelText: l10n.voucherPricingYourPrice,
                hintText: row.companyPrice?.toStringAsFixed(2),
              ),
              onSubmitted: (_) => _save(),
            ),
          ),
          IconButton(
            key: ValueKey('pricing_card_save_${row.variantId}'),
            tooltip: l10n.voucherPricingSave,
            onPressed: busy || _typed == null ? null : _save,
            icon: const Icon(Icons.check_rounded),
          ),
          if (custom)
            IconButton(
              key: ValueKey('pricing_card_follow_${row.variantId}'),
              tooltip: l10n.voucherPricingFollowCompany,
              onPressed: busy
                  ? null
                  : () => widget.viewModel.saveCardPrice(row, null),
              icon: const Icon(Icons.undo_rounded),
            ),
        ],
      ),
    );
  }
}
