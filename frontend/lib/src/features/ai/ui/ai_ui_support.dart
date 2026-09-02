import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:intl/intl.dart';

import '../../../shared/charts/charts.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';

/// The identifier the backend stamps on every generated surface. Client and
/// server must agree on it; a surface with any other catalog id is refused.
const String pointyAiCatalogId = 'https://pointy.app/ai-ui/v1';

/// Semantic tones. These are the only appearance control the model has: it
/// says what a thing *means*, never what colour it is.
enum AiTone { neutral, info, success, warning, danger }

const List<String> aiToneNames = <String>[
  'neutral',
  'info',
  'success',
  'warning',
  'danger',
];

AiTone aiToneFrom(String? value) => switch (value) {
  'info' => AiTone.info,
  'success' => AiTone.success,
  'warning' => AiTone.warning,
  'danger' => AiTone.danger,
  _ => AiTone.neutral,
};

/// Resolves a tone to the palette colour for the active theme.
Color aiToneColor(BuildContext context, AiTone tone) {
  final colors = context.pointyColors;
  return switch (tone) {
    AiTone.neutral => colors.mutedInk,
    AiTone.info => colors.primaryStrong,
    AiTone.success => colors.success,
    AiTone.warning => colors.warning,
    AiTone.danger => colors.danger,
  };
}

IconData aiToneIcon(AiTone tone) => switch (tone) {
  AiTone.neutral => Icons.info_outline,
  AiTone.info => Icons.lightbulb_outline,
  AiTone.success => Icons.check_circle_outline,
  AiTone.warning => Icons.warning_amber_outlined,
  AiTone.danger => Icons.error_outline,
};

/// Text roles. Mapped to the Pointy type ramp, never to a font size.
const List<String> aiTextVariants = <String>[
  'title',
  'subtitle',
  'body',
  'caption',
  'numeric',
];

TextStyle? aiTextStyle(
  BuildContext context,
  String? variant,
  String? emphasis,
) {
  final theme = Theme.of(context).textTheme;
  final base = switch (variant) {
    'title' => theme.titleMedium,
    'subtitle' => theme.titleSmall,
    'caption' => theme.bodySmall?.copyWith(
      color: context.pointyColors.mutedInk,
    ),
    'numeric' => theme.titleMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
    _ => theme.bodyMedium,
  };
  if (emphasis == 'strong') {
    return base?.copyWith(fontWeight: FontWeight.w700);
  }
  return base;
}

/// How a number should be rendered. The model states the kind; the client owns
/// the formatting, so currency symbols and digit shaping stay consistent.
const List<String> aiValueKinds = <String>[
  'text',
  'number',
  'money',
  'percent',
  'date',
];

final NumberFormat _decimal = NumberFormat.decimalPattern('en');

String aiFormatValue(Object? value, String? kind) {
  if (value == null) return '';
  switch (kind) {
    case 'money':
      final number = _asDouble(value);
      return number == null ? '$value' : formatMoney(number);
    case 'percent':
      final number = _asDouble(value);
      if (number == null) return '$value';
      final trimmed = number == number.roundToDouble()
          ? number.toStringAsFixed(0)
          : number.toStringAsFixed(1);
      return '$trimmed%';
    case 'number':
      final number = _asDouble(value);
      return number == null ? '$value' : _decimal.format(number);
    case 'date':
      final parsed = DateTime.tryParse('$value');
      return parsed == null
          ? '$value'
          : DateFormat('yyyy/MM/dd', 'en').format(parsed);
    default:
      return '$value';
  }
}

PointyChartValueKind aiChartValueKind(String? kind) => switch (kind) {
  'percent' => PointyChartValueKind.percent,
  'number' => PointyChartValueKind.number,
  _ => PointyChartValueKind.money,
};

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse('$value');
}

/// Reads a possibly-bound value out of the data model and returns it directly.
///
/// Bound *scalars* go through genui's `Bound*` widgets so they rebuild on
/// change. This helper is for list-shaped and object-shaped properties read
/// once at build time inside a [BoundList] builder.
Object? aiResolve(DataContext dataContext, Object? value) {
  if (value is Map && value.containsKey('path')) {
    return dataContext.getValue<Object>(DataPath(value['path'] as String));
  }
  return value;
}

/// Reads a list property that may be a literal list or a `{path}` binding.
List<Map<String, Object?>> aiResolveMapList(
  DataContext dataContext,
  Object? value,
) {
  final resolved = aiResolve(dataContext, value);
  if (resolved is! List) return const <Map<String, Object?>>[];
  return <Map<String, Object?>>[
    for (final entry in resolved)
      if (entry is Map) entry.cast<String, Object?>(),
  ];
}

String aiString(Map<String, Object?> map, String key, {String fallback = ''}) {
  final value = map[key];
  return value == null ? fallback : '$value';
}

double aiDouble(Map<String, Object?> map, String key) {
  return _asDouble(map[key]) ?? 0;
}

/// Dispatches a catalog action. Every interactive item funnels through here so
/// the three action families stay uniform.
void aiDispatchAction(
  CatalogItemContext itemContext,
  Map<String, Object?>? action,
) {
  if (action == null) return;
  final event = action['event'];
  if (event is! Map) return;
  final name = event['name'];
  if (name is! String || name.isEmpty) return;
  final context = event['context'];
  itemContext.dispatchEvent(
    UserActionEvent(
      name: name,
      sourceComponentId: itemContext.id,
      context: context is Map
          ? context.cast<String, Object?>()
          : <String, Object?>{},
    ),
  );
}
