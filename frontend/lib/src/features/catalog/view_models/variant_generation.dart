import '../../../data/models/variant_option.dart';
import '../../../data/models/variant_option_value.dart';

class VariantCombination {
  const VariantCombination(this.values);

  final List<VariantOptionValue> values;

  List<int> get valueIds => [for (final value in values) value.id];

  String get signature {
    final ids = [...valueIds]..sort();
    return ids.join('|');
  }

  String get autoName => values
      .map((value) => value.name.trim())
      .where((name) => name.isNotEmpty)
      .join(' ');

  String skuFromBase(String baseSku) {
    final base = _cleanSkuPart(baseSku, fallback: '');
    if (base.isEmpty) {
      // No prefix typed means this shop keeps no SKU scheme: leave the rows
      // blank for the server to code, rather than filling a whole catalog
      // with variants called SKU-RED.
      return '';
    }
    final suffix = values
        .map((value) => _cleanSkuPart(value.code, fallback: '${value.id}'))
        .where((part) => part.isNotEmpty)
        .join('-');
    return suffix.isEmpty ? base : '$base-$suffix';
  }
}

List<VariantCombination> generateVariantCombinations({
  required List<VariantOption> options,
  required Map<int, Set<int>> selectedValueIdsByOption,
}) {
  final selectedValuesByOption = <List<VariantOptionValue>>[];
  for (final option in options) {
    final selectedValueIds = selectedValueIdsByOption[option.id] ?? const {};
    if (selectedValueIds.isEmpty) {
      return const [];
    }
    final values = [
      for (final value in option.values)
        if (selectedValueIds.contains(value.id)) value,
    ];
    if (values.isEmpty) {
      return const [];
    }
    selectedValuesByOption.add(values);
  }

  final combinations = <VariantCombination>[];
  void visit(int optionIndex, List<VariantOptionValue> picked) {
    if (optionIndex == selectedValuesByOption.length) {
      combinations.add(VariantCombination(List.unmodifiable(picked)));
      return;
    }
    for (final value in selectedValuesByOption[optionIndex]) {
      visit(optionIndex + 1, [...picked, value]);
    }
  }

  if (selectedValuesByOption.isNotEmpty) {
    visit(0, const []);
  }
  return combinations;
}

String _cleanSkuPart(String value, {required String fallback}) {
  final normalized = value.trim().toUpperCase();
  final matches = RegExp(r'[A-Z0-9]+').allMatches(normalized);
  final cleaned = matches.map((match) => match.group(0)!).join('-');
  return cleaned.isEmpty ? fallback.toUpperCase() : cleaned;
}
