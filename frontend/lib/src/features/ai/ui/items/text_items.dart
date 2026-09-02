import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../../../shared/components/components.dart';
import '../ai_ui_schemas.dart';
import '../ai_ui_support.dart';

final aiText = CatalogItem(
  name: 'Text',
  dataSchema: S.object(
    description: 'A line or short paragraph of plain text.',
    properties: {
      'text': A2uiSchemas.stringReference(description: 'The text to show.'),
      'variant': S.string(
        description:
            'The role of this text. Use "numeric" for figures so digits align.',
        enumValues: aiTextVariants,
      ),
      'emphasis': S.string(
        description: 'Whether the text is emphasised.',
        enumValues: ['normal', 'strong'],
      ),
      'tone': AiSchemas.tone(
        description: 'Optional meaning, which tints the text.',
      ),
    },
    required: ['text'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "Text", "text": "إجمالي مبيعات اليوم",
        "variant": "title", "emphasis": "strong"}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final tone = data['tone'] as String?;
    return BoundString(
      dataContext: itemContext.dataContext,
      value: data['text'],
      builder: (context, value) {
        var style = aiTextStyle(
          context,
          data['variant'] as String?,
          data['emphasis'] as String?,
        );
        if (tone != null) {
          style = style?.copyWith(
            color: aiToneColor(context, aiToneFrom(tone)),
          );
        }
        return Text(value ?? '', style: style);
      },
    );
  },
);

final aiMarkdown = CatalogItem(
  name: 'Markdown',
  dataSchema: S.object(
    description:
        'Formatted prose with lists, bold and links. Use for explanation, not '
        'for figures — figures belong in MetricGrid, Table or a chart.',
    properties: {
      'text': A2uiSchemas.stringReference(description: 'Markdown source.'),
    },
    required: ['text'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "Markdown",
        "text": "**السبب:** ارتفاع الطلب في نهاية الأسبوع."}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    return BoundString(
      dataContext: itemContext.dataContext,
      value: data['text'],
      builder: (context, value) {
        return GptMarkdown(
          value ?? '',
          style: Theme.of(context).textTheme.bodyMedium,
        );
      },
    );
  },
);

final aiCallout = CatalogItem(
  name: 'Callout',
  dataSchema: S.object(
    description:
        'A single highlighted finding, warning or recommendation. Use at most '
        'one or two per answer, for the thing that matters most.',
    properties: {
      'title': A2uiSchemas.stringReference(description: 'The headline.'),
      'body': A2uiSchemas.stringReference(description: 'Optional detail line.'),
      'tone': AiSchemas.tone(),
    },
    required: ['title'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "Callout", "tone": "warning",
        "title": "٣ أصناف قاربت على النفاد",
        "body": "تكفي أقل من أسبوع بالمعدل الحالي."}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final tone = aiToneFrom(data['tone'] as String?);
    final title = aiResolve(itemContext.dataContext, data['title']);
    final body = aiResolve(itemContext.dataContext, data['body']);
    return PointyDetailCallout(
      icon: aiToneIcon(tone),
      title: '$title',
      message: body == null ? null : '$body',
      tone: switch (tone) {
        AiTone.success => PointyCalloutTone.success,
        AiTone.warning => PointyCalloutTone.warning,
        AiTone.danger => PointyCalloutTone.danger,
        AiTone.info => PointyCalloutTone.primary,
        AiTone.neutral => PointyCalloutTone.neutral,
      },
    );
  },
);

final aiStatusPill = CatalogItem(
  name: 'StatusPill',
  dataSchema: S.object(
    description: 'A compact status label, e.g. an order state.',
    properties: {
      'label': A2uiSchemas.stringReference(description: 'Pill text.'),
      'tone': AiSchemas.tone(),
    },
    required: ['label'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "StatusPill", "label": "مدفوعة",
        "tone": "success"}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final label = aiResolve(itemContext.dataContext, data['label']);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: PointyStatusPill(
        label: '$label',
        color: aiToneColor(
          itemContext.buildContext,
          aiToneFrom(data['tone'] as String?),
        ),
      ),
    );
  },
);

final List<CatalogItem> aiTextItems = <CatalogItem>[
  aiText,
  aiMarkdown,
  aiCallout,
  aiStatusPill,
];
