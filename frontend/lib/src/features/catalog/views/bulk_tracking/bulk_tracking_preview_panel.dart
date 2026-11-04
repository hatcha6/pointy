import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/bulk_tracking_change.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../../../shared/tracking/tracking_labels.dart';
import '../../../../data/models/tracking_mode.dart';
import '../../view_models/bulk_tracking_view_model.dart';

/// What the server says the change would do: counts, the two warnings that
/// need a decision, and every product with its outcome.
class BulkTrackingPreviewPanel extends StatefulWidget {
  const BulkTrackingPreviewPanel({
    super.key,
    required this.viewModel,
    required this.preview,
  });

  final BulkTrackingViewModel viewModel;
  final BulkTrackingPreview preview;

  @override
  State<BulkTrackingPreviewPanel> createState() =>
      _BulkTrackingPreviewPanelState();
}

class _BulkTrackingPreviewPanelState extends State<BulkTrackingPreviewPanel> {
  static const _pageSize = 50;
  int _shown = _pageSize;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final viewModel = widget.viewModel;
    final summary = widget.preview.summary;
    final rows = viewModel.rows.toList(growable: false);
    final visible = rows.take(_shown).toList(growable: false);
    final warnings =
        (summary.emptyShelf > 0 ? 1 : 0) + (summary.undatedStock > 0 ? 1 : 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryStrip(summary: summary),
        if (warnings > 0) ...[
          const SizedBox(height: 10),
          _Warnings(viewModel: viewModel, summary: summary),
        ],
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final (view, label, count) in [
                (
                  BulkTrackingListView.change,
                  l10n.bulkTrackingSummaryChange,
                  summary.change,
                ),
                (
                  BulkTrackingListView.blocked,
                  l10n.bulkTrackingSummaryBlocked,
                  summary.blocked,
                ),
                (
                  BulkTrackingListView.same,
                  l10n.bulkTrackingSummarySame,
                  summary.same,
                ),
              ])
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: ChoiceChip(
                    key: ValueKey('bulk_tracking_view_${view.name}'),
                    label: Text('$label  $count'),
                    selected: viewModel.view == view,
                    onSelected: (_) {
                      setState(() => _shown = _pageSize);
                      viewModel.setView(view);
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: PointyEmptyState(
              icon: Icons.inventory_2_outlined,
              title: summary.matched == 0
                  ? l10n.bulkTrackingNoMatch
                  : l10n.bulkTrackingEmptyView,
            ),
          )
        else ...[
          for (final row in visible) ...[
            _RowTile(row: row),
            const Divider(height: 1),
          ],
          if (rows.length > visible.length)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: OutlinedButton.icon(
                  key: const ValueKey('bulk_tracking_show_more'),
                  onPressed: () => setState(() => _shown += _pageSize),
                  icon: const Icon(Icons.expand_more),
                  label: Text(
                    '${l10n.bulkTrackingShowMore} (${rows.length - visible.length})',
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.summary});

  final BulkTrackingSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final tiles = [
      (l10n.bulkTrackingSummaryMatched, summary.matched, colors.ink),
      (l10n.bulkTrackingSummaryChange, summary.change, colors.primaryStrong),
      (l10n.bulkTrackingSummarySame, summary.same, colors.mutedInk),
      (
        l10n.bulkTrackingSummaryBlocked,
        summary.blocked,
        summary.blocked > 0 ? colors.danger : colors.mutedInk,
      ),
    ];
    return Row(
      children: [
        for (final (label, value, tint) in tiles)
          Expanded(
            child: Container(
              margin: const EdgeInsetsDirectional.only(end: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: colors.surfaceSunken,
                borderRadius: BorderRadius.circular(PointyRadii.card),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: colors.mutedInk),
                  ),
                  Text(
                    '$value',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: tint,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The two things that go wrong after a bulk switch, said in plain words
/// before anyone applies.
class _Warnings extends StatelessWidget {
  const _Warnings({required this.viewModel, required this.summary});

  final BulkTrackingViewModel viewModel;
  final BulkTrackingSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (summary.emptyShelf > 0) ...[
          PointyInlineMessage.warning(
            key: const ValueKey('bulk_tracking_empty_shelf_warning'),
            message: l10n.bulkTrackingEmptyShelfWarning(summary.emptyShelf),
          ),
          CheckboxListTile(
            key: const ValueKey('bulk_tracking_exclude_empty'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: viewModel.excludeEmptyShelf,
            onChanged: viewModel.isApplying
                ? null
                : (value) => viewModel.setExcludeEmptyShelf(value ?? false),
            title: Text(l10n.bulkTrackingExcludeEmpty),
            subtitle: viewModel.excludeEmptyShelf
                ? Text(
                    l10n.bulkTrackingExcludeEmptyHint(
                      viewModel.skippedEmptyShelf,
                    ),
                  )
                : null,
          ),
        ],
        if (summary.undatedStock > 0) ...[
          if (summary.emptyShelf > 0) const SizedBox(height: 6),
          PointyInlineMessage.warning(
            key: const ValueKey('bulk_tracking_undated_warning'),
            message: l10n.bulkTrackingUndatedWarning(summary.undatedStock),
          ),
        ],
      ],
    );
  }
}

class _RowTile extends StatelessWidget {
  const _RowTile({required this.row});

  final BulkTrackingRow row;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final mode = trackingModeLabel(
      l10n,
      TrackingMode.fromWire(row.currentMode),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                mode,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.mutedInk,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            l10n.bulkTrackingRowDetail(
              formatPrintedQuantity(row.onHand),
              row.variants,
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          if (row.outcome == BulkTrackingOutcome.blocked &&
              row.message.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              row.message,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
            ),
          ],
          if (row.warnings.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (row.isEmptyShelf)
                  PointyStatusPill(
                    label: l10n.bulkTrackingTagEmptyShelf,
                    color: context.pointyColors.warning,
                  ),
                if (row.isUndatedStock)
                  PointyStatusPill(
                    label: l10n.bulkTrackingTagUndated,
                    color: context.pointyColors.warning,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
