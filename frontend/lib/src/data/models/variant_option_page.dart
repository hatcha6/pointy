import 'variant_option.dart';

class VariantOptionPage {
  const VariantOptionPage({required this.options, required this.hasMore});

  final List<VariantOption> options;
  final bool hasMore;

  factory VariantOptionPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(VariantOption.fromJson)
        .toList(growable: false);

    return VariantOptionPage(options: results, hasMore: json['next'] != null);
  }
}
