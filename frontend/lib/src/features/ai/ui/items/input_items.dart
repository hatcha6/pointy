import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../ai_ui_support.dart';

/// Writes a value back into the surface data model so a later `submit:` action
/// carries it.
void _write(CatalogItemContext itemContext, Object? binding, Object? value) {
  if (binding is! Map || binding['path'] is! String) return;
  itemContext.dataContext.update(DataPath(binding['path'] as String), value);
}

/// Writes a number, matching the numeric type already sitting at that path.
///
/// The data model's backing store is typed by whatever seeded it, so writing a
/// double into a slot seeded with an int throws and the edit is lost silently.
/// Coercing to the existing type keeps a plain quantity an int and a price a
/// double; the fallback covers a slot that was empty or held something else.
void _writeNumber(
  CatalogItemContext itemContext,
  Object? binding,
  double? value,
) {
  if (binding is! Map || binding['path'] is! String) return;
  if (value == null) {
    _write(itemContext, binding, null);
    return;
  }
  final path = DataPath(binding['path'] as String);
  final existing = itemContext.dataContext.getValue<Object>(path);
  final isIntegral = value == value.roundToDouble();
  final Object next = switch (existing) {
    int _ when isIntegral => value.toInt(),
    double _ => value,
    _ => isIntegral ? value.toInt() : value,
  };
  try {
    itemContext.dataContext.update(path, next);
  } on TypeError {
    // The slot insists on the other numeric type; give it that instead.
    itemContext.dataContext.update(path, next is int ? value : value.toInt());
  }
}

final aiTextField = CatalogItem(
  name: 'TextField',
  dataSchema: S.object(
    description: 'A single-line text input bound to a path in the data model.',
    properties: {
      'label': S.string(description: 'Field label.'),
      'value': A2uiSchemas.stringReference(
        description: 'A {"path": "/..."} binding holding the entered text.',
      ),
      'placeholder': S.string(),
    },
    required: ['label', 'value'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "TextField", "label": "اسم المورد",
        "value": {"path": "/supplier/name"}}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    return _AiTextField(
      label: data['label'] as String? ?? '',
      placeholder: data['placeholder'] as String?,
      initial: '${aiResolve(itemContext.dataContext, data['value']) ?? ''}',
      onChanged: (value) => _write(itemContext, data['value'], value),
    );
  },
);

class _AiTextField extends StatefulWidget {
  const _AiTextField({
    required this.label,
    required this.initial,
    required this.onChanged,
    this.placeholder,
    this.keyboardType,
  });

  final String label;
  final String initial;
  final String? placeholder;
  final TextInputType? keyboardType;
  final ValueChanged<String> onChanged;

  @override
  State<_AiTextField> createState() => _AiTextFieldState();
}

class _AiTextFieldState extends State<_AiTextField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      keyboardType: widget.keyboardType,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.placeholder,
      ),
      onChanged: widget.onChanged,
    );
  }
}

final aiNumberField = CatalogItem(
  name: 'NumberField',
  dataSchema: S.object(
    description: 'A numeric input, e.g. a quantity or a cost.',
    properties: {
      'label': S.string(),
      'value': A2uiSchemas.numberReference(
        description: 'A {"path": "/..."} binding holding the number.',
      ),
      'unit': S.string(description: 'Optional unit shown after the field.'),
      'min': S.number(),
      'max': S.number(),
      'decimals': S.integer(description: 'Allowed decimal places, 0 to 3.'),
    },
    required: ['label', 'value'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "NumberField", "label": "الكمية",
        "decimals": 0, "min": 1, "value": {"path": "/line/quantity"}}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final decimals = (data['decimals'] as num?)?.toInt() ?? 2;
    return _AiTextField(
      label: data['label'] as String? ?? '',
      placeholder: data['unit'] as String?,
      keyboardType: TextInputType.numberWithOptions(decimal: decimals > 0),
      initial: '${aiResolve(itemContext.dataContext, data['value']) ?? ''}',
      onChanged: (raw) =>
          _writeNumber(itemContext, data['value'], double.tryParse(raw)),
    );
  },
);

final aiCheckbox = CatalogItem(
  name: 'Checkbox',
  dataSchema: S.object(
    description: 'A single on/off choice.',
    properties: {
      'label': S.string(),
      'value': A2uiSchemas.booleanReference(
        description: 'A {"path": "/..."} binding holding the boolean.',
      ),
    },
    required: ['label', 'value'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "Checkbox", "label": "استلمت البضاعة",
        "value": {"path": "/received"}}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    return BoundBool(
      dataContext: itemContext.dataContext,
      value: data['value'],
      builder: (context, checked) {
        return CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          value: checked ?? false,
          title: Text(data['label'] as String? ?? ''),
          onChanged: (next) => _write(itemContext, data['value'], next),
        );
      },
    );
  },
);

final aiChoiceChips = CatalogItem(
  name: 'ChoiceChips',
  dataSchema: S.object(
    description:
        'A small set of choices, shown as chips. Prefer this over a dropdown '
        'when there are six options or fewer.',
    properties: {
      'label': S.string(),
      'options': S.list(
        items: S.object(
          properties: {'value': S.string(), 'label': S.string()},
          required: ['value', 'label'],
        ),
      ),
      'value': A2uiSchemas.stringReference(
        description: 'A {"path": "/..."} binding holding the chosen value.',
      ),
    },
    required: ['options', 'value'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "ChoiceChips", "label": "الفترة",
        "value": {"path": "/period"},
        "options": [
          {"value": "week", "label": "أسبوع"},
          {"value": "month", "label": "شهر"}
        ]}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final options = <Map<String, Object?>>[
      for (final entry in (data['options'] as List? ?? const <Object?>[]))
        if (entry is Map) entry.cast<String, Object?>(),
    ];
    return BoundString(
      dataContext: itemContext.dataContext,
      value: data['value'],
      builder: (context, selected) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (data['label'] != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${data['label']}',
                  style: aiTextStyle(context, 'caption', null),
                ),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in options)
                  ChoiceChip(
                    label: Text(aiString(option, 'label')),
                    selected: selected == aiString(option, 'value'),
                    onSelected: (_) => _write(
                      itemContext,
                      data['value'],
                      aiString(option, 'value'),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  },
);

final aiForm = CatalogItem(
  name: 'Form',
  dataSchema: S.object(
    description:
        'Groups inputs with a submit button. On submit the whole surface data '
        'model is sent back to you, so read the values from the paths you bound.',
    properties: {
      'child': A2uiSchemas.componentReference(
        description: 'The component holding the inputs.',
      ),
      'submitLabel': S.string(description: 'Submit button text.'),
      'action': S.object(
        description: 'Must use a "submit:" event name.',
        properties: {
          'event': S.object(
            properties: {'name': S.string(), 'context': S.object()},
            required: ['name'],
          ),
        },
        required: ['event'],
      ),
    },
    required: ['child', 'submitLabel', 'action'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "Form", "child": "fields",
        "submitLabel": "احسب",
        "action": {"event": {"name": "submit:calc"}}},
       {"id": "fields", "component": "NumberField", "label": "الكمية",
        "value": {"path": "/qty"}}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final action = (data['action'] as Map?)?.cast<String, Object?>();
    // Inputs read badly when they stretch the full width of a wide surface, so
    // a generated form keeps a single centred column at a comfortable measure
    // and grows no further, the way the app's own forms do.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            itemContext.buildChild(data['child'] as String),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => aiDispatchAction(itemContext, action),
              child: Text(data['submitLabel'] as String? ?? ''),
            ),
          ],
        ),
      ),
    );
  },
);

final List<CatalogItem> aiInputItems = <CatalogItem>[
  aiTextField,
  aiNumberField,
  aiCheckbox,
  aiChoiceChips,
  aiForm,
];
