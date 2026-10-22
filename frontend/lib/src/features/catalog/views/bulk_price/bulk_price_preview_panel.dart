import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/bulk_price_preview.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../view_models/bulk_price_editor_view_model.dart';
import 'bulk_price_labels.dart';

/// The live answer to "what will these rules do": totals, a slice picker and
/// every affected row with its old and new price.
class BulkPricePreviewPanel extends StatelessWidget {
  const BulkPricePreviewPanel({super.key, required this.viewModel});

  final BulkPriceEditorViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final preview = viewModel.preview;
    final fresh = viewModel.isPreviewFresh;

    final Widget? notice;
    if (viewModel.spec.steps.isEmpty) {
      notice = PointyInlineMessage.warning(
        message: l10n.bulkPricePreviewNoSteps,
      );
    } else if (!viewModel.isComplete) {
      notice = PointyInlineMessage.warning(
        message: l10n.bulkPricePreviewIncomplete(viewModel.invalidCount),
      );
    } else if (viewModel.previewFailed) {
      notice = PointyInlineMessage.error(
        message: l10n.bulkPricePreviewFailed,
        trailing: TextButton(
          onPressed: viewModel.refreshPreview,
          child: Text(l10n.bulkPricePreviewRetry),
        ),
      );
    } else {
      notice = null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.bulkPricePreviewTab,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            if (viewModel.isPreviewing) ...[
              const SizedBox.square(
                dimension: 16,
                child: PointySpinner(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                l10n.bulkPricePreviewUpdating,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.pointyColors.mutedInk,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        if (notice != null) ...[notice, const SizedBox(height: 8)],
        if (preview == null)
          Expanded(
            child: viewModel.isPreviewing || !viewModel.optionsLoaded
                ? const Center(child: PointySpinner())
                : const SizedBox.shrink(),
          )
        else
          Expanded(
            // Stale numbers stay readable but visibly not current.
            child: AnimatedOpacity(
              duration: PointyMotion.fast,
              opacity: fresh ? 1 : 0.45,
              child: IgnorePointer(
                ignoring: !fresh,
                child: _PreviewBody(viewModel: viewModel, preview: preview),
              ),
            ),
          ),
      ],
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({required this.viewModel, required this.preview});

  final BulkPriceEditorViewModel viewModel;
  final BulkPricePreview preview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = preview.summary;
    final rows = preview.rows;
    final showMore = preview.hasMore;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: BulkPriceSummaryStrip(summary: summary)),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        SliverToBoxAdapter(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final view in BulkPricePreviewView.values)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: ChoiceChip(
                      key: ValueKey('bulk_price_view_${view.name}'),
                      label: Text(
                        '${l10n.viewLabel(view)}  ${summary.countFor(view)}',
                      ),
                      selected: viewModel.view == view,
                      onSelected: (_) => viewModel.setView(view),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        if (rows.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: PointyEmptyState(
              icon: summary.matched == 0
                  ? Icons.filter_alt_off_outlined
                  : Icons.price_check,
              title: summary.matched == 0
                  ? l10n.bulkPricePreviewNoMatch
                  : (viewModel.view == BulkPricePreviewView.changed
                        ? l10n.bulkPricePreviewNothingChanges
                        : l10n.bulkPricePreviewEmptyView),
            ),
          )
        else
          SliverList.separated(
            itemCount: rows.length + (showMore ? 1 : 0),
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              if (index == rows.length) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: viewModel.isLoadingMore
                        ? const PointySpinner()
                        : OutlinedButton.icon(
                            onPressed: viewModel.loadMore,
                            icon: const Icon(Icons.expand_more),
                            label: Text(
                              '${l10n.bulkPriceLoadMore} (${preview.count - rows.length})',
                            ),
                          ),
                  ),
                );
              }
              return BulkPricePreviewRowTile(
                row: rows[index],
                costVisible: preview.costVisible,
              );
            },
          ),
      ],
    );
  }
}

/// The headline numbers. Compact, so it fits above the list on a phone.
class BulkPriceSummaryStrip extends StatelessWidget {
  const BulkPriceSummaryStrip({super.key, required this.summary});

  final BulkPriceSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final average = summary.averageChangePercent;
    final tiles = [
      _Stat(label: l10n.bulkPriceSummaryMatched, value: '${summary.matched}'),
      _Stat(
        label: l10n.bulkPriceSummaryChanged,
        value: '${summary.changed}',
        accent: colors.primaryStrong,
        subtitle: summary.packsChanged > 0
            ? l10n.bulkPricePacksChanged(summary.packsChanged)
            : null,
      ),
      _Stat(
        label:
            '${l10n.bulkPriceSummaryIncreased} / ${l10n.bulkPriceSummaryDecreased}',
        value: '↑${summary.increased}  ↓${summary.decreased}',
      ),
      _Stat(
        label: l10n.bulkPriceSummaryAverage,
        value: average == null ? '—' : bulkPricePercent(average, signed: true),
      ),
      if (summary.warnings > 0)
        _Stat(
          label: l10n.bulkPriceSummaryWarnings,
          value: '${summary.warnings}',
          accent: colors.warning,
          icon: Icons.warning_amber_rounded,
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 560 ? tiles.length : 2;
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tile in tiles) SizedBox(width: width, child: tile),
          ],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.accent,
    this.subtitle,
    this.icon,
  });

  final String label;
  final String value;
  final Color? accent;
  final String? subtitle;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final tint = accent ?? colors.ink;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: accent == null
            ? colors.surfaceSunken
            : Color.alphaBlend(tint.withValues(alpha: 0.08), colors.surface),
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: Border.all(
          color: accent == null ? colors.line : tint.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: tint),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              value,
              maxLines: 1,
              style: switch (theme.textTheme.titleMedium?.copyWith(
                color: tint,
                fontWeight: FontWeight.w800,
              )) {
                final style? => PointyTypography.numeric(style),
                null => null,
              },
            ),
          ),
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
        ],
      ),
    );
  }
}

class BulkPricePreviewRowTile extends StatelessWidget {
  const BulkPricePreviewRowTile({
    super.key,
    required this.row,
    required this.costVisible,
  });

  final BulkPricePreviewRow row;
  final bool costVisible;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk);
    final changed = row.priceChanged;
    final up = row.increased;
    final deltaColor = !changed
        ? colors.mutedInk
        : (up ? colors.success : colors.accentAmber);

    final details = <String>[
      if (row.sku.isNotEmpty) ltrIsolated(row.sku),
      if (costVisible && row.cost != null)
        l10n.bulkPriceRowCost(formatMoney(row.cost!)),
      if (costVisible && row.oldMarkup != null && row.newMarkup != null)
        l10n.bulkPriceRowMarkup(
          bulkPricePercent(row.oldMarkup!),
          bulkPricePercent(row.newMarkup!),
        ),
      if (row.appliedSteps.isNotEmpty)
        l10n.bulkPriceRowSteps(
          row.appliedSteps.map((index) => '${index + 1}').join('، '),
        ),
    ];

    final priceStyle = PointyTypography.numeric(
      theme.textTheme.titleSmall!.copyWith(fontWeight: FontWeight.w800),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: row.productName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (row.variantName.isNotEmpty)
                        TextSpan(text: ' · ${row.variantName}', style: muted),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (details.isNotEmpty)
                  Text(details.join('  ·  '), style: muted, maxLines: 2),
                if (row.flags.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final flag in row.flags)
                        PointyStatusPill(
                          label: l10n.flagLabel(flag),
                          color: bulkPriceFlagColor(context, flag),
                        ),
                    ],
                  ),
                ],
                for (final pack in row.packs)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Icon(
                          Icons.inventory_outlined,
                          size: 14,
                          color: colors.mutedInk,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            '${pack.label}: ${formatMoney(pack.oldPrice)} ← ${formatMoney(pack.newPrice)}',
                            style: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (changed) ...[
                    Text(
                      formatMoney(row.oldPrice),
                      style: muted?.copyWith(
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(
                        Icons.arrow_forward,
                        size: 14,
                        color: colors.mutedInk,
                      ),
                    ),
                  ],
                  Text(
                    formatMoney(row.newPrice),
                    style: priceStyle.copyWith(
                      color: changed ? colors.ink : colors.mutedInk,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              PointyStatusPill(
                label: !changed
                    ? l10n.bulkPriceUnchangedBadge
                    : (row.deltaPercent == null
                          ? formatMoney(row.newPrice - row.oldPrice)
                          : bulkPricePercent(row.deltaPercent!, signed: true)),
                icon: !changed
                    ? null
                    : (up ? Icons.arrow_upward : Icons.arrow_downward),
                color: deltaColor,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
