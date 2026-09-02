import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../../../shared/design/design.dart';
import '../ai_ui_schemas.dart';
import '../ai_ui_support.dart';

final aiButton = CatalogItem(
  name: 'Button',
  dataSchema: S.object(
    description:
        'A tap target. Use it to open a screen, ask a follow-up, or submit the '
        'inputs on this surface.',
    properties: {
      'label': A2uiSchemas.stringReference(description: 'Button text.'),
      'variant': S.string(
        description: 'How prominent the button is.',
        enumValues: ['primary', 'secondary', 'destructive'],
      ),
      'icon': S.string(
        description: 'Optional meaning-based icon.',
        enumValues: ['open', 'add', 'refresh', 'check', 'chart', 'search'],
      ),
      'action': AiSchemas.action(),
    },
    required: ['label', 'action'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "Button", "label": "افتح المنتج",
        "variant": "secondary", "icon": "open",
        "action": {"event": {"name": "navigate:product",
          "context": {"link": "pointy://product/12"}}}}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final action = (data['action'] as Map?)?.cast<String, Object?>();
    final icon = switch (data['icon'] as String?) {
      'open' => Icons.arrow_outward_rounded,
      'add' => Icons.add_rounded,
      'refresh' => Icons.refresh_rounded,
      'check' => Icons.check_rounded,
      'chart' => Icons.insights_rounded,
      'search' => Icons.search_rounded,
      _ => null,
    };
    return BoundString(
      dataContext: itemContext.dataContext,
      value: data['label'],
      builder: (context, label) => _AiActionChip(
        label: label ?? '',
        icon: icon,
        variant: data['variant'] as String?,
        onTap: () => aiDispatchAction(itemContext, action),
      ),
    );
  },
);

/// A suggested next step inside a reply.
///
/// Deliberately not a Material button: a filled button carries the weight of a
/// form's primary action, which is far too loud sitting under a paragraph. This
/// reads as an offer — the same soft, bordered language as the cards above it —
/// and stays legible in both themes.
class _AiActionChip extends StatefulWidget {
  const _AiActionChip({
    required this.label,
    required this.onTap,
    this.icon,
    this.variant,
  });

  final String label;
  final IconData? icon;
  final String? variant;
  final VoidCallback onTap;

  @override
  State<_AiActionChip> createState() => _AiActionChipState();
}

class _AiActionChipState extends State<_AiActionChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final isPrimary = widget.variant == 'primary';
    final isDestructive = widget.variant == 'destructive';

    final foreground = isDestructive
        ? colors.danger
        : isPrimary
        ? colors.primaryStrong
        : colors.ink;
    final background = isPrimary
        ? colors.primaryContainer
        : _hovered
        ? colors.subtleFill
        : colors.surface;
    final border = isPrimary
        ? Colors.transparent
        : isDestructive
        ? colors.danger.withValues(alpha: 0.35)
        : colors.line;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: PointyMotion.fast,
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(PointyRadii.pill),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 16, color: foreground),
                const SizedBox(width: 7),
              ],
              Text(
                widget.label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: foreground,
                  fontWeight: isPrimary ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final aiEntityChip = CatalogItem(
  name: 'EntityChip',
  dataSchema: S.object(
    description:
        'A reference to a record in the shop — a product, customer, supplier, '
        'sale or purchase order. Tapping it opens that record.',
    properties: {
      'label': A2uiSchemas.stringReference(description: 'The record name.'),
      'entity': S.string(
        description: 'Which kind of record this is.',
        enumValues: [
          'product',
          'customer',
          'supplier',
          'order',
          'purchase-order',
          'job',
        ],
      ),
      'entityId': A2uiSchemas.stringReference(
        description: 'The record id in the database.',
      ),
    },
    required: ['label', 'entity', 'entityId'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "EntityChip", "entity": "product",
        "entityId": "12", "label": "شاي أخضر ٢٠٠غ"}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final entity = data['entity'] as String? ?? 'product';
    final entityId = aiResolve(itemContext.dataContext, data['entityId']);
    final icon = switch (entity) {
      'customer' => Icons.person_outline,
      'supplier' => Icons.local_shipping_outlined,
      'order' => Icons.receipt_long_outlined,
      'purchase-order' => Icons.inventory_2_outlined,
      'job' => Icons.build_outlined,
      _ => Icons.sell_outlined,
    };
    return BoundString(
      dataContext: itemContext.dataContext,
      value: data['label'],
      builder: (context, label) {
        final colors = context.pointyColors;
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: InkWell(
            borderRadius: BorderRadius.circular(PointyRadii.pill),
            onTap: () => aiDispatchAction(itemContext, {
              'event': {
                'name': 'navigate:entity',
                'context': {'link': 'pointy://$entity/$entityId'},
              },
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(PointyRadii.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 15, color: colors.primaryStrong),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colors.primaryStrong,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  },
);

final List<CatalogItem> aiActionItems = <CatalogItem>[aiButton, aiEntityChip];
