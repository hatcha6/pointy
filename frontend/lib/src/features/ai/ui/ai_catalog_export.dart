import 'ai_ui_support.dart';
import 'pointy_ai_catalog.dart';

/// The catalog as plain JSON, for the backend's validator and prompt.
///
/// Emits each item's JSON Schema exactly as the renderer sees it, plus the
/// `component` discriminator genui injects. The backend refuses any payload
/// whose component or property is not in here, which is what stops generated
/// UI from drifting away from the product.
Map<String, Object?> exportAiCatalog() {
  return <String, Object?>{
    'catalogId': pointyAiCatalogId,
    r'$id': pointyAiCatalogId,
    'version': 1,
    'components': <String, Object?>{
      for (final item in PointyAiCatalog.items)
        item.name: _componentSchema(item.dataSchema.value),
    },
  };
}

/// Strips the schema down to what the backend needs: description, properties
/// (with their descriptions and enums) and the required list.
Map<String, Object?> _componentSchema(Map<String, Object?> schema) {
  final properties = <String, Object?>{};
  final raw = schema['properties'];
  if (raw is Map) {
    for (final entry in raw.entries) {
      final key = '${entry.key}';
      // `component` is genui's own discriminator; the backend adds it itself.
      if (key == 'component') continue;
      final value = entry.value;
      properties[key] = value is Map
          ? _property(value.cast<String, Object?>())
          : <String, Object?>{};
    }
  }
  final required = <String>[
    for (final entry in (schema['required'] as List? ?? const <Object?>[]))
      if ('$entry' != 'component') '$entry',
  ];
  return <String, Object?>{
    if (schema['description'] != null) 'description': schema['description'],
    'properties': properties,
    'required': required,
  };
}

Map<String, Object?> _property(Map<String, Object?> schema, {int depth = 0}) {
  final result = <String, Object?>{
    if (schema['description'] != null) 'description': schema['description'],
    if (schema['type'] != null) 'type': schema['type'],
    if (schema['enum'] != null) 'enum': schema['enum'],
  };
  // A property that accepts a data binding is a union in JSON Schema terms.
  // The backend only needs to know it is bindable, not the exact union.
  final bindable =
      schema.containsKey('oneOf') ||
      schema.containsKey('allOf') ||
      schema.containsKey(r'$ref');
  if (bindable) result['bindable'] = true;

  if (depth >= 3) return result;

  // Recurse into list item and nested object shapes: a Table's column
  // definition or a MetricGrid's metric shape is exactly what the model has to
  // get right, so it must survive the export.
  final items = _listItemSchema(schema);
  if (items != null) {
    result['items'] = _property(items, depth: depth + 1);
  }
  final nested = schema['properties'];
  if (nested is Map && nested.isNotEmpty) {
    result['properties'] = <String, Object?>{
      for (final entry in nested.entries)
        '${entry.key}': entry.value is Map
            ? _property(
                (entry.value as Map).cast<String, Object?>(),
                depth: depth + 1,
              )
            : <String, Object?>{},
    };
    final required = schema['required'];
    if (required is List && required.isNotEmpty) {
      result['required'] = <String>[for (final r in required) '$r'];
    }
  }
  return result;
}

/// Finds the element schema of a list property, including a list hidden inside
/// a "literal list or data binding" union.
Map<String, Object?>? _listItemSchema(Map<String, Object?> schema) {
  final direct = schema['items'];
  if (direct is Map) return direct.cast<String, Object?>();
  for (final key in const ['oneOf', 'anyOf', 'allOf']) {
    final branches = schema[key];
    if (branches is! List) continue;
    for (final branch in branches) {
      if (branch is! Map) continue;
      final items = branch['items'];
      if (items is Map) return items.cast<String, Object?>();
    }
  }
  return null;
}
