import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/stock_unit.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/tracking/stock_voucher_labels.dart';

/// An article's life in time order: where it went (allocations) and what was
/// done to it without moving it (§6.9 events) — who repriced it, who rewrote
/// its condition, who changed its warranty, who added or removed a photo.
///
/// Read from the merged timeline when the server has one. An older backend
/// answers only the movements, which still render — the half that matters most.
class StockUnitTimelineSection extends StatelessWidget {
  const StockUnitTimelineSection({
    super.key,
    required this.history,
    required this.timeline,
  });

  final List<StockAllocationEntry> history;
  final List<StockUnitTimelineEntry> timeline;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final rows = timeline.isNotEmpty
        ? [for (final entry in timeline) _timelineRow(l10n, entry)]
        : [for (final entry in history) _historyRow(l10n, entry)];

    return PointyDetailSection(
      title: l10n.stockUnitTimelineSection,
      icon: Icons.timeline_outlined,
      child: rows.isEmpty
          ? Text(
              l10n.stockUnitHistoryEmpty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.mutedInk,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final row in rows)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(row.icon, size: 18, color: colors.mutedInk),
                    title: Text(row.title),
                    subtitle: Text(
                      row.details.join(' · '),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
    );
  }

  _Row _historyRow(AppLocalizations l10n, StockAllocationEntry entry) {
    return _Row(
      icon: entry.isIncoming
          ? Icons.south_west_outlined
          : Icons.north_east_outlined,
      title: stockVoucherLabel(l10n, entry.voucherType),
      details: [
        if (entry.postingAt != null) formatDateTime(entry.postingAt!),
        if (entry.warehouseName.isNotEmpty) entry.warehouseName,
      ],
    );
  }

  _Row _timelineRow(AppLocalizations l10n, StockUnitTimelineEntry entry) {
    if (entry.isAllocation) {
      return _Row(
        icon: entry.kind == 'in'
            ? Icons.south_west_outlined
            : Icons.north_east_outlined,
        title: stockVoucherLabel(l10n, entry.voucherType),
        details: [
          formatDateTime(entry.at),
          if (entry.warehouseName.isNotEmpty) entry.warehouseName,
        ],
      );
    }
    // An attribute edit says what the facts became; the from-side names the
    // same fields again and only doubles the line.
    final change = entry.kind == 'attributes_edited'
        ? entry.toValue
        : entry.fromValue.isEmpty && entry.toValue.isEmpty
        ? ''
        : entry.fromValue.isEmpty
        ? entry.toValue
        : l10n.unitTimelineFromTo(
            entry.fromValue,
            entry.toValue.isEmpty ? '—' : entry.toValue,
          );
    return _Row(
      icon: _eventIcon(entry.kind),
      title: eventLabel(l10n, entry.kind),
      details: [
        formatDateTime(entry.at),
        if (entry.actorName.isNotEmpty) entry.actorName,
        if (change.isNotEmpty) change,
        // An attribute edit's note names the fields; its from/to already says
        // what they became, so the note would only repeat it.
        if (entry.note.isNotEmpty && entry.kind != 'attributes_edited')
          entry.note,
      ],
    );
  }

  static IconData _eventIcon(String kind) => switch (kind) {
    'repriced' => Icons.sell_outlined,
    'attributes_edited' => Icons.fact_check_outlined,
    'warranty_changed' => Icons.verified_user_outlined,
    'photo_added' => Icons.add_photo_alternate_outlined,
    'photo_removed' => Icons.hide_image_outlined,
    'written_off' => Icons.delete_outline,
    _ => Icons.edit_note_outlined,
  };

  /// A server event kind, in Arabic. A kind this client has no word for is
  /// still something that happened; it says so rather than show the code.
  static String eventLabel(AppLocalizations l10n, String kind) {
    return switch (kind) {
      'repriced' => l10n.unitTimelineEventRepriced,
      'identified' => l10n.unitTimelineEventIdentified,
      'written_off' => l10n.unitTimelineEventWrittenOff,
      'incident' => l10n.unitTimelineEventIncident,
      'counted' => l10n.unitTimelineEventCounted,
      'relocated' => l10n.unitTimelineEventRelocated,
      'advance_opened' => l10n.unitTimelineEventAdvanceOpened,
      'advance_settled' => l10n.unitTimelineEventAdvanceSettled,
      'identifier_corrected' => l10n.unitTimelineEventIdentifierCorrected,
      'attributes_edited' => l10n.unitTimelineEventAttributesEdited,
      'refurb_cost' => l10n.unitTimelineEventRefurbCost,
      'warranty_changed' => l10n.unitTimelineEventWarrantyChanged,
      'photo_added' => l10n.unitTimelineEventPhotoAdded,
      'photo_removed' => l10n.unitTimelineEventPhotoRemoved,
      _ => l10n.unitTimelineEventNote,
    };
  }
}

class _Row {
  const _Row({required this.icon, required this.title, required this.details});

  final IconData icon;
  final String title;
  final List<String> details;
}
