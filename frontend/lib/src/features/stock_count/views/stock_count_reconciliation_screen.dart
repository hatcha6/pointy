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

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.stockCountReconciliationTitle),
            isLoading: _viewModel.isApplying,
          ),
          body: PointyDataList<StockCountLine>(
            items: _viewModel.lines,
            isLoadingInitial: _viewModel.isLoading,
            isLoadingMore: false,
            hasMore: false,
            hasError: _viewModel.hasLoadError,
            onLoadMore: () async {},
            padding: AdaptiveSpacing.of(context).pagePadding,
            header: _Header(count: _viewModel.lines.length),
            emptyBuilder: (context) => PointyEmptyState(
              icon: Icons.check_circle_outline,
              title: l10n.stockCountNoVariances,
            ),
            errorBuilder: (context) => PointyEmptyState(
              icon: Icons.error_outline,
              title: l10n.stockCountLoadError,
            ),
            itemBuilder: (context, line) => _ReconciliationTile(
              line: line,
              onRecount: _isReadOnly ? null : () => _recount(line),
            ),
          ),
          bottomNavigationBar: _buildBottom(context, l10n),
        );
      },
    );
  }

  Widget? _buildBottom(BuildContext context, AppLocalizations l10n) {
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
    return PointyStickyActionFooter(
      primaryAction: FilledButton.icon(
        onPressed: _viewModel.isApplying ? null : _apply,
        icon: const Icon(Icons.fact_check_outlined),
        label: Text(l10n.stockCountApply),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: EdgeInsetsDirectional.only(bottom: spacing.sm),
      child: Text(
        l10n.stockCountMismatchCount(count),
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
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
        '${gapPositive ? '+' : '-'}${formatQuantity(line.variance.abs())}';

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
                  size: 44,
                ),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: Text(
                    name,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (line.variance != 0)
                  Text(
                    gapText,
                    style: PointyTypography.numeric(
                      textTheme.titleMedium ?? const TextStyle(),
                    ).copyWith(color: gapColor, fontWeight: FontWeight.w800),
                  ),
              ],
            ),
            SizedBox(height: spacing.sm),
            Row(
              children: [
                Expanded(
                  child: _Metric(
                    label: l10n.stockCountColumnExpected,
                    value: formatQuantity(line.expectedQuantity),
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: l10n.stockCountColumnCounted,
                    value: formatQuantity(line.countedQuantity),
                  ),
                ),
                if (onRecount != null)
                  TextButton.icon(
                    onPressed: onRecount,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(l10n.stockCountRecount),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

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
        Text(
          value,
          style: PointyTypography.numeric(
            textTheme.titleSmall ?? const TextStyle(),
          ).copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}
