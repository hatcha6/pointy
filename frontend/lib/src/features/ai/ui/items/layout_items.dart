import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../ai_ui_support.dart';

const double _stackSpacing = 10;

CrossAxisAlignment _crossAxis(String? value) => switch (value) {
  'center' => CrossAxisAlignment.center,
  'end' => CrossAxisAlignment.end,
  'stretch' => CrossAxisAlignment.stretch,
  _ => CrossAxisAlignment.start,
};

Widget _childrenBuilder(
  CatalogItemContext itemContext, {
  required Object? children,
  required Widget Function(List<Widget> built) assemble,
}) {
  return ComponentChildrenBuilder(
    childrenData: children,
    dataContext: itemContext.dataContext,
    buildChild: itemContext.buildChild,
    getComponent: itemContext.getComponent,
    explicitListBuilder: (childIds, buildChild, getComponent, dataContext) {
      return assemble([for (final id in childIds) buildChild(id, dataContext)]);
    },
    templateListWidgetBuilder: (context, data, componentId, dataBinding) {
      final values = switch (data) {
        final List list => list,
        final Map map => map.values.toList(),
        _ => const <Object?>[],
      };
      return assemble([
        for (var index = 0; index < values.length; index += 1)
          itemContext.buildChild(
            componentId,
            itemContext.dataContext.nested(DataPath('$dataBinding/$index')),
          ),
      ]);
    },
  );
}

final aiColumn = CatalogItem(
  name: 'Column',
  dataSchema: S.object(
    description: 'Stacks its children vertically. The usual page container.',
    properties: {
      'children': A2uiSchemas.componentArrayReference(
        description:
            'Child component ids, or a template bound to a list in the data '
            'model.',
      ),
      'align': S.string(
        description: 'Cross-axis alignment.',
        enumValues: ['start', 'center', 'end', 'stretch'],
      ),
    },
    required: ['children'],
  ),
  exampleData: [
    () => '''
      [
        {"id": "root", "component": "Column", "children": ["a", "b"]},
        {"id": "a", "component": "Text", "text": "الأعلى"},
        {"id": "b", "component": "Text", "text": "الأسفل"}
      ]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    return _childrenBuilder(
      itemContext,
      children: data['children'],
      assemble: (built) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: _crossAxis(data['align'] as String? ?? 'stretch'),
        spacing: _stackSpacing,
        children: built,
      ),
    );
  },
);

final aiRow = CatalogItem(
  name: 'Row',
  dataSchema: S.object(
    description:
        'Places its children side by side. Use for two or three short items; '
        'prefer Column on a phone.',
    properties: {
      'children': A2uiSchemas.componentArrayReference(
        description: 'Child component ids, or a bound template.',
      ),
      'justify': S.string(
        description: 'Main-axis distribution.',
        enumValues: ['start', 'center', 'end', 'spaceBetween'],
      ),
      'align': S.string(
        description: 'Cross-axis alignment.',
        enumValues: ['start', 'center', 'end', 'stretch'],
      ),
    },
    required: ['children'],
  ),
  exampleData: [
    () => '''
      [
        {"id": "root", "component": "Row", "children": ["a", "b"],
         "justify": "spaceBetween"},
        {"id": "a", "component": "Text", "text": "الإجمالي"},
        {"id": "b", "component": "Text", "text": "120.00", "variant": "numeric"}
      ]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final justify = data['justify'] as String?;
    return _childrenBuilder(
      itemContext,
      children: data['children'],
      assemble: (built) {
        // "spaceBetween" is the label-and-value pattern, which needs a real Row
        // so the two ends actually reach the edges.
        if (justify == 'spaceBetween') {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: _crossAxis(
              data['align'] as String? ?? 'center',
            ),
            spacing: _stackSpacing,
            children: [for (final child in built) Flexible(child: child)],
          );
        }
        // Everything else lays out at its natural width and wraps rather than
        // overflowing. Sharing the width equally between flexible children is
        // what pushed a pair of buttons to opposite edges of the reply.
        return Wrap(
          spacing: _stackSpacing,
          runSpacing: _stackSpacing,
          alignment: switch (justify) {
            'center' => WrapAlignment.center,
            'end' => WrapAlignment.end,
            _ => WrapAlignment.start,
          },
          crossAxisAlignment: WrapCrossAlignment.center,
          children: built,
        );
      },
    );
  },
);

final aiCard = CatalogItem(
  name: 'Card',
  dataSchema: S.object(
    description:
        'A titled panel that groups related content. Use one card per idea.',
    properties: {
      'child': A2uiSchemas.componentReference(
        description: 'The id of the component inside the card.',
      ),
      'title': A2uiSchemas.stringReference(description: 'Optional heading.'),
      'subtitle': A2uiSchemas.stringReference(
        description: 'Optional line under the heading, e.g. the period.',
      ),
    },
    required: ['child'],
  ),
  exampleData: [
    () => '''
      [
        {"id": "root", "component": "Card", "title": "مبيعات الأسبوع",
         "child": "body"},
        {"id": "body", "component": "Text", "text": "ارتفعت 12%."}
      ]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final colors = itemContext.buildContext.pointyColors;
    final title = aiResolve(itemContext.dataContext, data['title']);
    final subtitle = aiResolve(itemContext.dataContext, data['subtitle']);
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: Border.all(color: colors.line),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null && '$title'.isNotEmpty) ...[
            Text(
              '$title',
              style: aiTextStyle(itemContext.buildContext, 'title', 'strong'),
            ),
            if (subtitle != null && '$subtitle'.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '$subtitle',
                  style: aiTextStyle(itemContext.buildContext, 'caption', null),
                ),
              ),
            const SizedBox(height: 12),
          ],
          itemContext.buildChild(data['child'] as String),
        ],
      ),
    );
  },
);

final aiSection = CatalogItem(
  name: 'Section',
  dataSchema: S.object(
    description: 'A labelled block inside a longer answer.',
    properties: {
      'title': A2uiSchemas.stringReference(description: 'Section heading.'),
      'child': A2uiSchemas.componentReference(description: 'Section body id.'),
    },
    required: ['title', 'child'],
  ),
  exampleData: [
    () => '''
      [
        {"id": "root", "component": "Section", "title": "التوصيات",
         "child": "body"},
        {"id": "body", "component": "Text", "text": "أعد طلب ٣ أصناف."}
      ]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final title = aiResolve(itemContext.dataContext, data['title']);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointySectionHeader(
          title: '$title',
          padding: const EdgeInsets.only(bottom: 8),
        ),
        itemContext.buildChild(data['child'] as String),
      ],
    );
  },
);

final aiDivider = CatalogItem(
  name: 'Divider',
  dataSchema: S.object(
    description: 'A thin rule separating two blocks.',
    properties: const {},
  ),
  exampleData: [() => '[{"id": "root", "component": "Divider"}]'],
  widgetBuilder: (itemContext) {
    return Divider(
      height: 1,
      thickness: 1,
      color: itemContext.buildContext.pointyColors.line,
    );
  },
);

final List<CatalogItem> aiLayoutItems = <CatalogItem>[
  aiColumn,
  aiRow,
  aiCard,
  aiSection,
  aiDivider,
];
