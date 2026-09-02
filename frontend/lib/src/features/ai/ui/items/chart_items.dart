import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../../../shared/charts/charts.dart';
import '../ai_ui_schemas.dart';
import '../ai_ui_support.dart';

final _seriesSchema = S.object(
  description: 'One named run of values.',
  properties: {
    'name': S.string(description: 'Series name, shown in the legend.'),
    'points': S.list(
      description: 'The values, in order along the category axis.',
      items: S.object(
        properties: {
          'label': S.string(
            description: 'Category label, e.g. a date or name.',
          ),
          'value': S.number(),
        },
        required: ['label', 'value'],
      ),
    ),
  },
  required: ['name', 'points'],
);

List<PointyChartSeries> _readSeries(DataContext dataContext, Object? value) {
  final raw = aiResolveMapList(dataContext, value);
  return <PointyChartSeries>[
    for (final entry in raw)
      PointyChartSeries(
        name: aiString(entry, 'name'),
        points: <PointyChartPoint>[
          for (final point in aiResolveMapList(dataContext, entry['points']))
            PointyChartPoint(
              label: aiString(point, 'label'),
              value: aiDouble(point, 'value'),
            ),
        ],
      ),
  ];
}

final aiLineChart = CatalogItem(
  name: 'LineChart',
  dataSchema: S.object(
    description:
        'A trend over time. Use when the question is about direction or a '
        'series of days, weeks or months.',
    properties: {
      'series': AiSchemas.records(item: _seriesSchema),
      'kind': AiSchemas.valueKind(
        description: 'How the plotted values should be formatted.',
      ),
    },
    required: ['series'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "LineChart", "kind": "money", "series": [
        {"name": "المبيعات", "points": [
          {"label": "السبت", "value": 1200},
          {"label": "الأحد", "value": 1580},
          {"label": "الاثنين", "value": 990}
        ]}
      ]}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    return PointyLineChart(
      series: _readSeries(itemContext.dataContext, data['series']),
      valueKind: aiChartValueKind(data['kind'] as String?),
    );
  },
);

final aiBarChart = CatalogItem(
  name: 'BarChart',
  dataSchema: S.object(
    description:
        'A comparison across categories, e.g. products, branches or hours.',
    properties: {
      'series': AiSchemas.records(item: _seriesSchema),
      'kind': AiSchemas.valueKind(),
    },
    required: ['series'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "BarChart", "kind": "number", "series": [
        {"name": "الكمية", "points": [
          {"label": "شاي", "value": 42},
          {"label": "سكر", "value": 31},
          {"label": "أرز", "value": 18}
        ]}
      ]}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    return PointyBarChart(
      series: _readSeries(itemContext.dataContext, data['series']),
      valueKind: aiChartValueKind(data['kind'] as String?),
    );
  },
);

final aiDonutChart = CatalogItem(
  name: 'DonutChart',
  dataSchema: S.object(
    description:
        'A share of a whole, e.g. payment mix. Use only when the parts really '
        'do sum to the total, and keep it under six slices.',
    properties: {
      'slices': AiSchemas.records(
        item: S.object(
          properties: {'label': S.string(), 'value': S.number()},
          required: ['label', 'value'],
        ),
      ),
      'kind': AiSchemas.valueKind(),
    },
    required: ['slices'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "DonutChart", "kind": "money", "slices": [
        {"label": "نقدي", "value": 820},
        {"label": "بطاقة", "value": 410}
      ]}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final slices = aiResolveMapList(itemContext.dataContext, data['slices']);
    return PointyDonutChart(
      slices: [
        for (final slice in slices)
          PointyChartSlice(
            label: aiString(slice, 'label'),
            value: aiDouble(slice, 'value'),
          ),
      ],
      valueKind: aiChartValueKind(data['kind'] as String?),
    );
  },
);

final aiSparkline = CatalogItem(
  name: 'Sparkline',
  dataSchema: S.object(
    description:
        'A tiny trend line with no axes, for placing beside a single figure.',
    properties: {
      'points': AiSchemas.records(
        item: S.object(
          properties: {'label': S.string(), 'value': S.number()},
          required: ['value'],
        ),
      ),
    },
    required: ['points'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "Sparkline", "points": [
        {"value": 4}, {"value": 9}, {"value": 6}, {"value": 12}
      ]}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final points = aiResolveMapList(itemContext.dataContext, data['points']);
    return PointySparkline(
      points: [
        for (final point in points)
          PointyChartPoint(
            label: aiString(point, 'label'),
            value: aiDouble(point, 'value'),
          ),
      ],
    );
  },
);

final List<CatalogItem> aiChartItems = <CatalogItem>[
  aiLineChart,
  aiBarChart,
  aiDonutChart,
  aiSparkline,
];
