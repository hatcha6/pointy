import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/stock_count.dart';
import '../../../data/models/stock_count_line.dart';
import '../../../data/repositories/stock_count_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/product_image_thumbnail.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/units.dart';
import '../view_models/stock_count_reconciliation_view_model.dart';
import 'stock_count_findings.dart';
import 'stock_count_ui.dart';

/// The finish screen: only the lines that differ, then a manager-gated Apply.
class StockCountReconciliationScreen extends StatefulWidget {
  const StockCountReconciliationScreen({
    super.key,
    required this.session,
    required this.stockCountRepository,
    required this.capabilities,
    this.onRecountVariant,
  });

  final StockCount session;
  final StockCountRepository stockCountRepository;
  final AuthorizationCapabilities capabilities;
  final ValueChanged<ProductVariant>? onRecountVariant;

  @override
  State<StockCountReconciliationScreen> createState() =>
      _StockCountReconciliationScreenState();
}

class _StockCountReconciliationScreenState
    extends State<StockCountReconciliationScreen> {
  late final StockCountReconciliationViewModel _viewModel;

  bool get _isReadOnly => !widget.session.isInProgress;

  @override
  void initState() {
    super.initState();
    _viewModel = StockCountReconciliationViewModel(
      widget.stockCountRepository,
      session: widget.session,
    );
    _viewModel.load();
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  void _recount(StockCountLine line) {
    final variant = line.variant;
    if (variant == null) {
      return;
    }
    widget.onRecountVariant?.call(variant);
    Navigator.of(context).pop();
  }

  Future<void> _apply() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => PointyDestructiveConfirmationDialog(
        title: l10n.stockCountApplyConfirmTitle,
        message: l10n.stockCountApplyConfirmBody,
        confirmLabel: l10n.stockCountApplyConfirm,
        icon: Icons.fact_check_outlined,
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final applied = await _viewModel.apply();
    if (!mounted) {
      return;
    }
    if (applied != null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.stockCountApplied)));
      Navigator.of(context).pop(true);
    } else if (_viewModel.applyError) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.stockCountApplyError)));
      _viewModel.acknowledgeApplyError();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final lines = _viewModel.lines;

        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.stockCountReconciliationTitle),
            isLoading: _viewModel.isApplying,
          ),
          body: AdaptiveMaxWidth(
            width: AppContentWidth.detail,
            child: PointyDataList<StockCountLine>(
              items: lines,
              framed: false,
              isLoadingInitial: _viewModel.isLoading,
              isLoadingMore: false,
              hasMore: false,
              hasError: _viewModel.hasLoadError,
              onLoadMore: () async {},
              padding: spacing.pagePadding,
              separatorBuilder: (_, _) => SizedBox(height: spacing.sm),
              header: _header(context, lines, spacing),
              emptyBuilder: (context) => _MatchedState(),
              errorBuilder: (context) => PointyErrorState(
                title: l10n.stockCountReconciliationLoadError,
                action: OutlinedButton.icon(
                  onPressed: _viewModel.load,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.retryButton),
                ),
              ),
              itemBuilder: (context, line) => _ReconciliationTile(
                line: line,
                onRecount: _isReadOnly ? null : () => _recount(line),
              ),
            ),
          ),
          bottomNavigationBar: _buildBottom(context, l10n, lines.length),
        );
      },
    );
  }

  /// The variance summary, and — for a count that scanned anything — the
  /// four named lists a scanned count produces. Both, because a session can
  /// hold anonymous lines and identified ones at once: the same pharmacy
  /// counts serialised imports and local stock off one shelf.
  Widget? _header(
    BuildContext context,
    List<StockCountLine> lines,
    AdaptiveSpacing spacing,
  ) {
    final findings = _viewModel.findings;
    final showFindings = _viewModel.hasFindings && findings != null;
    if (lines.isEmpty && !showFindings) {
      return null;
    }
    return Padding(
      padding: EdgeInsetsDirectional.only(bottom: spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (lines.isNotEmpty)
            _SummaryCard(session: widget.session, lines: lines),
          if (showFindings) ...[
            if (lines.isNotEmpty) SizedBox(height: spacing.lg),
            StockCountFindingsCard(findings: findings),
          ],
        ],
      ),
    );
  }

  Widget? _buildBottom(
    BuildContext context,
    AppLocalizations l10n,
    int varianceCount,
  ) {
    if (_isReadOnly) {
      return null;
    }
    if (!widget.capabilities.canApplyStockCount) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: AdaptiveSpacing.of(context).compactPadding,
          child: PointyInlineMessage(
            message: l10n.stockCountApplyManagerOnly,
            icon: Icons.lock_outline,
          ),
        ),
      );
    }
    if (_viewModel.hasLoadError) {
      // A failed load empties `lines`, which is indistinguishable from a
      // matched count: without this the footer would offer a confident
      // "finish" on variances nobody has seen.
      return SafeArea(
        top: false,
        child: Padding(
          padding: AdaptiveSpacing.of(context).compactPadding,
          child: PointyInlineMessage.error(
            message: l10n.stockCountApplyBlockedByLoadError,
          ),
        ),
      );
    }
    // Apply stays available even with no variances: it is also how a matched
    // count is finalized. The label/summary soften when there is nothing to
    // adjust.
    final hasVariances = varianceCount > 0;
    return PointyStickyActionFooter(
      summary: hasVariances
          ? Text(
              l10n.stockCountApplySummary(varianceCount),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.pointyColors.mutedInk,
                fontWeight: FontWeight.w600,
              ),
            )
          : null,
      primaryAction: FilledButton.icon(
        onPressed: _viewModel.isApplying ? null : _apply,
        icon: Icon(
          hasVariances ? Icons.fact_check_outlined : Icons.check_circle_outline,
        ),
        label: Text(
          hasVariances ? l10n.stockCountApply : l10n.stockCountFinishCount,
        ),
      ),
    );
  }
}

/// The variance overview: how many lines differ, split into shortage / surplus.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.session, required this.lines});

  final StockCount session;
  final List<StockCountLine> lines;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final shortage = lines.where((line) => line.variance < 0).length;
    final surplus = lines.where((line) => line.variance > 0).length;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
        boxShadow: PointyShadows.raised,
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.stockCountMismatchCount(lines.length),
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                SizedBox(width: spacing.sm),
                StockCountScopeChip(session: session),
              ],
            ),
            SizedBox(height: spacing.md),
            Row(
              children: [
                Expanded(
                  child: _VarianceStat(
                    label: l10n.stockCountShortage,
                    count: shortage,
                    color: colors.danger,
                    icon: Icons.south_rounded,
                  ),
                ),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: _VarianceStat(
                    label: l10n.stockCountSurplus,
                    count: surplus,
                    color: colors.success,
                    icon: Icons.north_rounded,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _VarianceStat extends StatelessWidget {
  const _VarianceStat({
    required this.label,
    required this.count,
    required this.color,
    required this.icon,
  });

  final String label;
  final int count;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final active = count > 0;
    final tint = active ? color : colors.mutedInk;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: active
            ? Color.alphaBlend(color.withValues(alpha: 0.08), colors.surface)
            : colors.surfaceSunken,
        border: Border.all(
          color: active ? color.withValues(alpha: 0.22) : colors.line,
        ),
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: spacing.md,
          vertical: spacing.sm,
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: tint),
            SizedBox(width: spacing.sm),
            Text(
              label,
              style: textTheme.bodyMedium?.copyWith(
                color: colors.mutedInk,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              count.toString(),
              style: PointyTypography.numeric(
                textTheme.titleMedium ?? const TextStyle(),
              ).copyWith(color: tint, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

/// The celebratory matched state: nothing differs from the system.
class _MatchedState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: AdaptiveMaxWidth(
        width: AppContentWidth.compact,
        expand: false,
        child: Padding(
          padding: spacing.sectionPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: colors.success.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.check_circle_rounded,
                  size: 52,
                  color: colors.success,
                ),
              ),
              SizedBox(height: spacing.lg),
              Text(
                l10n.stockCountAllMatched,
                textAlign: TextAlign.center,
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: spacing.sm),
              Text(
                l10n.stockCountNoVariances,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReconciliationTile extends StatelessWidget {
  const _ReconciliationTile({required this.line, this.onRecount});

  final StockCountLine line;
  final VoidCallback? onRecount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final variant = line.variant;
    final name = variant?.displayLabel ?? '#${line.variantId}';
    final gapPositive = line.variance >= 0;
    final gapColor = gapPositive ? colors.success : colors.danger;
    final gapText =
        '${gapPositive ? '+' : '−'}${formatQuantity(line.variance.abs())}';
    final unitText = variant == null
        ? null
        : l10n.stockCountItemUnit(unitLabel(l10n, variant.unit));

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ProductImageThumbnail(
                  imageUrl: variant?.primaryImage?.contentUrl,
                  fallbackText: name,
                  size: 48,
                  borderRadius: 12,
                ),
                SizedBox(width: spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (unitText != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          unitText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: spacing.sm),
                _GapChip(text: gapText, color: gapColor),
              ],
            ),
            SizedBox(height: spacing.md),
            _ComparisonStrip(
              expected: formatQuantity(line.expectedQuantity),
              counted: formatQuantity(line.countedQuantity),
              countedColor: gapColor,
              onRecount: onRecount,
            ),
          ],
        ),
      ),
    );
  }
}

class _GapChip extends StatelessWidget {
  const _GapChip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: 0.12), colors.surface),
        border: Border.all(color: color.withValues(alpha: 0.24)),
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          text,
          style: PointyTypography.numeric(
            textTheme.titleMedium ?? const TextStyle(),
          ).copyWith(color: color, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

/// The system vs counted readout, plus the recount affordance while editable.
class _ComparisonStrip extends StatelessWidget {
  const _ComparisonStrip({
    required this.expected,
    required this.counted,
    required this.countedColor,
    this.onRecount,
  });

  final String expected;
  final String counted;
  final Color countedColor;
  final VoidCallback? onRecount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.input),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: spacing.md,
          vertical: spacing.sm,
        ),
        child: Row(
          children: [
            _Stat(label: l10n.stockCountColumnExpected, value: expected),
            SizedBox(width: spacing.lg),
            _Stat(
              label: l10n.stockCountColumnCounted,
              value: counted,
              valueColor: countedColor,
            ),
            const Spacer(),
            if (onRecount != null)
              TextButton.icon(
                onPressed: onRecount,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l10n.stockCountRecount),
              ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style:
              PointyTypography.numeric(
                textTheme.titleSmall ?? const TextStyle(),
              ).copyWith(
                color: valueColor ?? colors.ink,
                fontWeight: FontWeight.w800,
              ),
        ),
      ],
    );
  }
}
