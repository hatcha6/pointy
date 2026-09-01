import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/report_run.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../report_labels.dart';

/// The report, on screen.
///
/// Until now a report could only be produced, never looked at: the screen was a
/// form with three buttons, and the only way to see a figure was to build a PDF.
/// When gross profit looked wrong there was nowhere to go but out of the tab.
///
/// Three things this view does that the PDF cannot:
///
/// * a truncated schedule is marked *before* its rows, not after, because the
///   reader scrolling a long table needs to know it is short before they start
///   adding it up;
/// * a totals row is pinned to the bottom of every schedule that has one, in a
///   weight that distinguishes it from data;
/// * the comparison column shows the movement as well as the earlier figure,
///   because "up or down" is the first thing anybody asks of a number.
class ReportResultView extends StatelessWidget {
  const ReportResultView({
    super.key,
    required this.run,
    this.isStale = false,
    this.onOpenDocument,
  });

  final ReportRun run;

  /// The selection has changed since this result was built. It stays on screen
  /// — losing it on every knob-turn is worse — but it is marked, so nobody
  /// prints last week's window by mistake.
  final bool isStale;

  /// Called when a row that names a document is tapped, with the document's
  /// own reference. Rows that name nothing are not tappable — a row that looks
  /// interactive and does nothing is worse than a row that looks inert.
  final void Function(String reference)? onOpenDocument;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final payload = run.payload;
    final summary = _map(payload['summary']);
    final previous = _map(payload['previous_summary']);
    final headline = _stringList(payload['headline']);
    final sections = payload['sections'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isStale) ...[
          PointyInlineMessage.warning(message: l10n.reportResultStaleMessage),
          const SizedBox(height: 12),
        ],
        _PeriodBanner(payload: payload),
        const SizedBox(height: 16),
        if (summary.isNotEmpty)
          PointyMetricGrid(
            metrics: _headlineMetrics(summary, previous, headline),
          ),
        if (sections is List)
          for (final section in sections)
            if (section is Map && section['key'] != 'summary')
              _SectionCard(
                section: section.cast<String, Object?>(),
                onOpenDocument: onOpenDocument,
              ),
        _NotesCard(payload: payload),
      ],
    );
  }

  List<PointyMetricGridItem> _headlineMetrics(
    Map<String, Object?> summary,
    Map<String, Object?> previous,
    List<String> headline,
  ) {
    final ordered = <String>[
      ...headline.where(summary.containsKey),
      ...summary.keys.where((key) => !headline.contains(key)),
    ];
    return [
      for (final key in ordered)
        PointyMetricGridItem(
          label: reportLabel(key),
          value: reportValue(key, summary[key]),
          subtitle: _comparisonSubtitle(key, summary, previous),
        ),
    ];
  }

  String? _comparisonSubtitle(
    String key,
    Map<String, Object?> summary,
    Map<String, Object?> previous,
  ) {
    if (previous.isEmpty || !previous.containsKey(key)) {
      return null;
    }
    final earlier = reportValue(key, previous[key]);
    final change = reportChange(
      _changePercent(summary[key], previous[key]),
    );
    return change == null ? 'السابق: $earlier' : '$change · السابق: $earlier';
  }

  /// Computed here rather than read from the row, because the metric grid is
  /// built from the summary map and the movement lives on the summary section's
  /// rows. Same arithmetic, one place.
  String? _changePercent(Object? current, Object? previous) {
    final now = num.tryParse('$current');
    final before = num.tryParse('$previous');
    if (now == null || before == null || before == 0) {
      return null;
    }
    return (((now - before) / before.abs()) * 100).toStringAsFixed(2);
  }
}

class _PeriodBanner extends StatelessWidget {
  const _PeriodBanner({required this.payload});

  final Map<String, Object?> payload;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final period = _map(payload['period']);
    final audit = _map(payload['audit']);
    final closed = _hasNote(payload, 'period_closed');

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        PointyStatusPill(
          label: l10n.reportDateRangeValue(
            '${period['start_date']}',
            '${period['end_date']}',
          ),
          icon: Icons.event_outlined,
        ),
        PointyStatusPill(
          label: closed
              ? l10n.reportPeriodClosedChip
              : l10n.reportPeriodOpenChip,
          icon: closed ? Icons.lock_outline : Icons.lock_open_outlined,
          color: closed ? context.pointyColors.primaryStrong : null,
        ),
        if (audit['truncated'] == true)
          PointyStatusPill(
            label: l10n.reportTruncatedChip('${audit['omitted_count']}'),
            icon: Icons.filter_alt_outlined,
            color: context.pointyColors.warning,
          ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.section, this.onOpenDocument});

  final Map<String, Object?> section;
  final void Function(String reference)? onOpenDocument;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final columns = _stringList(section['columns']);
    final types = _map(section['column_types']);
    final rows = (section['rows'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => row.cast<String, Object?>())
        .toList(growable: false);
    final metadata = _map(section['metadata']);
    final truncated = metadata['truncated'] == true;

    if (columns.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            reportLabel('${section['key']}'),
            style: theme.textTheme.titleMedium,
          ),
          if (truncated) ...[
            const SizedBox(height: 6),
            Text(
              l10n.reportTruncatedNotice(
                '${metadata['returned_count']}',
                '${metadata['total_count']}',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: context.pointyColors.warning,
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (rows.isEmpty)
            Text(
              l10n.reportSectionEmpty,
              style: theme.textTheme.bodySmall,
            )
          else
            _SectionTable(
              columns: columns,
              types: types,
              rows: rows,
              totals: _map(section['totals']),
              truncated: truncated,
              onOpenDocument: onOpenDocument,
            ),
        ],
      ),
    );
  }
}

class _SectionTable extends StatelessWidget {
  const _SectionTable({
    required this.columns,
    required this.types,
    required this.rows,
    required this.totals,
    required this.truncated,
    this.onOpenDocument,
  });

  final List<String> columns;
  final Map<String, Object?> types;
  final List<Map<String, Object?>> rows;
  final Map<String, Object?> totals;
  final bool truncated;
  final void Function(String reference)? onOpenDocument;

  /// The columns that hold a document a reader can go and look at.
  static const _referenceColumns = [
    'receipt_number',
    'document',
    'order_number',
    'run_number',
    'session_number',
  ];

  String? _referenceOf(Map<String, Object?> row) {
    for (final column in _referenceColumns) {
      final value = row[column]?.toString().trim() ?? '';
      if (value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final shown = _map(totals['shown']);
    final full = _map(totals['full']);

    return Card.filled(
      margin: EdgeInsets.zero,
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        // Wide schedules scroll inside their own card; the page never scrolls
        // sideways under them.
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 40,
          dataRowMinHeight: 36,
          dataRowMaxHeight: 52,
          columnSpacing: 24,
          columns: [
            for (final column in columns)
              DataColumn(
                label: Text(
                  reportLabel(column),
                  style: theme.textTheme.labelLarge,
                ),
                numeric: reportColumnIsNumeric('${types[column]}'),
              ),
          ],
          rows: [
            for (final row in rows)
              DataRow(
                onSelectChanged: _rowAction(row),
                cells: [
                  for (final column in columns)
                    DataCell(
                      Text(
                        reportValue(
                          column,
                          row[column],
                          columnType: '${types[column]}',
                        ),
                      ),
                    ),
                ],
              ),
            if (shown.isNotEmpty)
              _totalsRow(
                context,
                truncated ? l10n.reportTotalsShownLabel : reportLabel('total'),
                shown,
                emphasised: true,
              ),
            // Both totals, or a reader cannot tell a complete schedule from a
            // short one.
            if (shown.isNotEmpty && truncated && !_sameTotals(shown, full))
              _totalsRow(context, l10n.reportTotalsFullLabel, full),
          ],
        ),
      ),
    );
  }

  /// A row is tappable only when it names something to open.
  ValueChanged<bool?>? _rowAction(Map<String, Object?> row) {
    final open = onOpenDocument;
    if (open == null) {
      return null;
    }
    final reference = _referenceOf(row);
    if (reference == null) {
      return null;
    }
    return (_) => open(reference);
  }

  DataRow _totalsRow(
    BuildContext context,
    String label,
    Map<String, Object?> values, {
    bool emphasised = false,
  }) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: emphasised ? FontWeight.w700 : FontWeight.w600,
      color: emphasised ? null : context.pointyColors.mutedInk,
    );
    return DataRow(
      color: WidgetStatePropertyAll(context.pointyColors.surfaceSunken),
      cells: [
        for (var index = 0; index < columns.length; index++)
          DataCell(
            Text(
              index == 0
                  ? label
                  : values.containsKey(columns[index])
                  ? reportValue(
                      columns[index],
                      values[columns[index]],
                      columnType: '${types[columns[index]]}',
                    )
                  : '',
              style: style,
            ),
          ),
      ],
    );
  }

  bool _sameTotals(Map<String, Object?> shown, Map<String, Object?> full) {
    if (full.isEmpty) {
      return true;
    }
    for (final entry in shown.entries) {
      if ('${full[entry.key]}' != '${entry.value}') {
        return false;
      }
    }
    return true;
  }
}

/// What each figure includes, which basis, which date rule.
///
/// The audit's finding was that nothing on a printed report said any of this,
/// so a reader comparing gross sales to the till found a difference and
/// concluded the report was broken.
class _NotesCard extends StatelessWidget {
  const _NotesCard({required this.payload});

  final Map<String, Object?> payload;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final notes = payload['notes'];
    if (notes is! List || notes.isEmpty) {
      return const SizedBox.shrink();
    }
    final sentences = <String>[
      for (final note in notes)
        if (note is Map)
          ?reportNote(
            '${note['code']}',
            args: _map(note['args']),
          ),
    ];
    if (sentences.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: PointyDetailCallout(
        icon: Icons.info_outline,
        title: l10n.reportNotesTitle,
        message: sentences.join('\n'),
      ),
    );
  }
}

bool _hasNote(Map<String, Object?> payload, String code) {
  final notes = payload['notes'];
  if (notes is! List) {
    return false;
  }
  return notes.any((note) => note is Map && note['code'] == code);
}

Map<String, Object?> _map(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.cast<String, Object?>();
  }
  return const {};
}

List<String> _stringList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return [
    for (final item in value)
      if (item != null) item.toString(),
  ];
}
