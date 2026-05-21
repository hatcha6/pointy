import 'variant_option_value.dart';

class VariantOptionValuePage {
  const VariantOptionValuePage({
    required this.optionValues,
    required this.hasMore,
  });

  final List<VariantOptionValue> optionValues;
  final bool hasMore;

  factory VariantOptionValuePage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(VariantOptionValue.fromJson)
        .toList(growable: false);

    return VariantOptionValuePage(
      optionValues: results,
      hasMore: json['next'] != null,
    );
  }
}
