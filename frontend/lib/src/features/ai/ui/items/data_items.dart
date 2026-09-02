import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../ai_ui_schemas.dart';
import '../ai_ui_support.dart';

final _metricSchema = S.object(
  properties: {
    'label': S.string(description: 'What the figure measures.'),
    'value': S.any(description: 'The figure itself.'),
    'kind': AiSchemas.valueKind(),
    'delta': S.number(
      description:
          'Optional change versus the comparison period, as a percentage. '
          'Positive means up. The client draws the arrow and colour.',
    ),
    'subtitle': S.string(
      description: 'Optional context line, e.g. the period.',
    ),
  },
  required: ['label', 'value'],
);

final aiMetricGrid = CatalogItem(
  name: 'MetricGrid',
  dataSchema: S.object(
    description:
        'Headline figures, two to six of them. The first thing to reach for '
        'when an answer contains several numbers.',
    properties: {
      'metrics': AiSchemas.records(
        item: _metricSchema,
        description: 'The figures, in order of importance.',
      ),
    },
    required: ['metrics'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "MetricGrid", "metrics": [
        {"label": "صافي المبيعات", "value": 12480.5, "kind": "money",
         "delta": 12.4, "subtitle": "آخر ٣٠ يوم"},
        {"label": "عدد الفواتير", "value": 318, "kind": "number"},
        {"label": "متوسط الفاتورة", "value": 39.2, "kind": "money"}
      ]}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    return BoundList(
      dataContext: itemContext.dataContext,
      value: data['metrics'],
      builder: (context, resolved) {
        final metrics = <Map<String, Object?>>[
          for (final entry in resolved ?? const <Object?>[])
            if (entry is Map) entry.cast<String, Object?>(),
        ];
        if (metrics.isEmpty) return const SizedBox.shrink();
        return PointyMetricGrid(
          minTileWidth: 150,
          maxColumns: metrics.length <= 4 ? metrics.length : 3,
          metrics: [
            for (final metric in metrics)
              PointyMetricGridItem(
                label: aiString(metric, 'label'),
                value: aiFormatValue(
                  metric['value'],
                  aiString(metric, 'kind', fallback: 'text'),
                ),
                subtitle: _deltaSubtitle(context, metric),
                accentColor: _deltaColor(context, metric),
              ),
          ],
        );
      },
    );
  },
);

String? _deltaSubtitle(BuildContext context, Map<String, Object?> metric) {
  final subtitle = metric['subtitle'];
  final delta = metric['delta'];
  final parts = <String>[];
  if (delta is num && delta != 0) {
    final arrow = delta > 0 ? '▲' : '▼';
    final magnitude = delta.abs() == delta.abs().roundToDouble()
        ? delta.abs().toStringAsFixed(0)
        : delta.abs().toStringAsFixed(1);
    parts.add('$arrow $magnitude%');
  }
  if (subtitle != null && '$subtitle'.isNotEmpty) parts.add('$subtitle');
  return parts.isEmpty ? null : parts.join(' · ');
}

Color? _deltaColor(BuildContext context, Map<String, Object?> metric) {
  final delta = metric['delta'];
  if (delta is! num || delta == 0) return null;
  final colors = context.pointyColors;
  return delta > 0 ? colors.success : colors.danger;
}

final aiSummaryList = CatalogItem(
  name: 'SummaryList',
  dataSchema: S.object(
    description:
        'Label-and-value rows, like an invoice breakdown. Use when the values '
        'add up to something, and mark the last row as the total.',
    properties: {
      'rows': AiSchemas.records(
        item: S.object(
          properties: {
            'label': S.string(),
            'value': S.any(),
            'kind': AiSchemas.valueKind(),
            'total': S.boolean(
              description: 'Marks this row as the emphasised total row.',
            ),
          },
          required: ['label', 'value'],
        ),
      ),
    },
    required: ['rows'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "SummaryList", "rows": [
        {"label": "المجموع", "value": 480, "kind": "money"},
        {"label": "الخصم", "value": 30, "kind": "money"},
        {"label": "الإجمالي", "value": 450, "kind": "money", "total": true}
      ]}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    return BoundList(
      dataContext: itemContext.dataContext,
      value: data['rows'],
      builder: (context, resolved) {
        final rows = <Map<String, Object?>>[
          for (final entry in resolved ?? const <Object?>[])
            if (entry is Map) entry.cast<String, Object?>(),
        ];
        if (rows.isEmpty) return const SizedBox.shrink();
        return PointySummaryList(
          rows: [
            for (final row in rows)
              PointySummaryRow(
                label: aiString(row, 'label'),
                value: aiFormatValue(
                  row['value'],
                  aiString(row, 'kind', fallback: 'text'),
                ),
                emphasized: row['total'] == true,
                dividerAbove: row['total'] == true,
              ),
          ],
        );
      },
    );
  },
);

final aiTable = CatalogItem(
  name: 'Table',
  dataSchema: S.object(
    description:
        'Rows of records with named columns. Use when the user needs to scan '
        'or compare more than about five records.',
    properties: {
      'columns': S.list(
        description: 'Column definitions, in display order.',
        items: S.object(
          properties: {
            'key': S.string(description: 'The field name in each row object.'),
            'label': S.string(description: 'The column heading.'),
            'kind': AiSchemas.valueKind(),
            'total': S.boolean(
              description:
                  'Sum this column in a totals row. Only set it where a sum '
                  'is meaningful: a line total or a quantity, never a unit '
                  'price, a percentage or an average.',
            ),
          },
          required: ['key', 'label'],
        ),
      ),
      'rows': AiSchemas.records(
        item: S.object(description: 'One record, keyed by column key.'),
        description:
            'The records. Include a "link" field on a row to make it tappable, '
            'e.g. "pointy://product/12".',
      ),
    },
    required: ['columns', 'rows'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "Table",
        "columns": [
          {"key": "name", "label": "الصنف"},
          {"key": "qty", "label": "الكمية", "kind": "number", "total": true},
          {"key": "total", "label": "الإجمالي", "kind": "money", "total": true}
        ],
        "rows": [
          {"name": "شاي", "qty": 12, "total": 240, "link": "pointy://product/1"},
          {"name": "سكر", "qty": 8, "total": 96}
        ]}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final columns = <Map<String, Object?>>[
      for (final entry in (data['columns'] as List? ?? const <Object?>[]))
        if (entry is Map) entry.cast<String, Object?>(),
    ];
    return BoundList(
      dataContext: itemContext.dataContext,
      value: data['rows'],
      builder: (context, resolved) {
        final rows = <Map<String, Object?>>[
          for (final entry in resolved ?? const <Object?>[])
            if (entry is Map) entry.cast<String, Object?>(),
        ];
        if (columns.isEmpty || rows.isEmpty) return const SizedBox.shrink();
        return _AiTable(
          columns: columns,
          rows: rows,
          onOpenLink: (link) => aiDispatchAction(itemContext, {
            'event': {
              'name': 'navigate:row',
              'context': {'link': link},
            },
          }),
        );
      },
    );
  },
);

class _AiTable extends StatelessWidget {
  const _AiTable({
    required this.columns,
    required this.rows,
    required this.onOpenLink,
  });

  final List<Map<String, Object?>> columns;
  final List<Map<String, Object?>> rows;
  final void Function(String link) onOpenLink;

  /// Whether any column asked to be summed.
  bool get _showTotals => columns.any((column) => column['total'] == true);

  bool _isNumeric(Map<String, Object?> column) {
    final kind = aiString(column, 'kind', fallback: 'text');
    return kind == 'money' || kind == 'number' || kind == 'percent';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final headingStyle = Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700);
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: Border.all(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      // Fill the card when the columns fit, and only scroll sideways when they
      // genuinely overflow — a table that hugs its content leaves a dead gap.
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: DataTable(
              // Rows are tappable via onSelectChanged, which would otherwise add a
              // selection checkbox column to every generated table.
              showCheckboxColumn: false,
              headingRowHeight: 40,
              dataRowMinHeight: 40,
              dataRowMaxHeight: 52,
              headingRowColor: WidgetStatePropertyAll(colors.subtleFill),
              border: TableBorder(
                horizontalInside: BorderSide(color: colors.line),
              ),
              columns: [
                for (final column in columns)
                  DataColumn(
                    numeric: _isNumeric(column),
                    label: Text(aiString(column, 'label'), style: headingStyle),
                  ),
              ],
              rows: [
                for (final row in rows)
                  DataRow(
                    onSelectChanged: row['link'] is String
                        ? (_) => onOpenLink(row['link'] as String)
                        : null,
                    cells: [
                      for (final column in columns)
                        DataCell(
                          Text(
                            aiFormatValue(
                              row[aiString(column, 'key')],
                              aiString(column, 'kind', fallback: 'text'),
                            ),
                            style: _isNumeric(column)
                                ? aiTextStyle(context, 'numeric', null)
                                : null,
                          ),
                        ),
                    ],
                  ),
                if (_showTotals) _totalsRow(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  DataRow _totalsRow(BuildContext context) {
    final style = aiTextStyle(context, 'numeric', 'strong');
    return DataRow(
      color: WidgetStatePropertyAll(context.pointyColors.subtleFill),
      cells: [
        for (var index = 0; index < columns.length; index += 1)
          DataCell(
            index == 0
                ? Text(
                    AppLocalizations.of(context)!.aiUiTableTotalRow,
                    style: style,
                  )
                : _totalCell(context, columns[index], style),
          ),
      ],
    );
  }

  Widget _totalCell(
    BuildContext context,
    Map<String, Object?> column,
    TextStyle? style,
  ) {
    // Only columns the model marked, and only where a sum means something.
    final kind = aiString(column, 'kind', fallback: 'text');
    if (column['total'] != true) return const SizedBox.shrink();
    if (kind != 'money' && kind != 'number') return const SizedBox.shrink();
    final key = aiString(column, 'key');
    final total = rows.fold<double>(0, (sum, row) => sum + aiDouble(row, key));
    return Text(aiFormatValue(total, kind), style: style);
  }
}

final List<CatalogItem> aiDataItems = <CatalogItem>[
  aiMetricGrid,
  aiSummaryList,
  aiTable,
];
