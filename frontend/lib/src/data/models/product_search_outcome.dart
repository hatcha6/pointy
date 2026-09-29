/// How the server found what it returned for a product search — or why it
/// returned nothing. Sent with the page as `search` since the search learned
/// to forgive: without it a till would show results for «عصير» under a box
/// that says «عصبر» and never say why.
enum ProductSearchMatch {
  /// The words as typed.
  exact,

  /// Retyped from the other keyboard layout («hgpgdf» → «الحليب»).
  layout,

  /// Corrected against the shop's own words (a slip, words run together).
  corrected,

  /// Near misses: similar spellings of the words.
  fuzzy,

  /// Nothing matched.
  none,
}

class ProductSearchOutcome {
  const ProductSearchOutcome({
    required this.match,
    this.correctedQuery,
    this.hiddenOutOfStock = 0,
    this.categoryFallback = false,
  });

  final ProductSearchMatch match;

  /// What was searched instead of the typed words, for [ProductSearchMatch.layout]
  /// and [ProductSearchMatch.corrected].
  final String? correctedQuery;

  /// Products that match but are out of stock, so the till hid them. Set only
  /// when nothing else was shown.
  final int hiddenOutOfStock;

  /// Nothing matched inside the selected category, so these come from all of
  /// them.
  final bool categoryFallback;

  /// Whether the results are something other than the typed words found as
  /// typed.
  bool get isApproximate =>
      match == ProductSearchMatch.layout ||
      match == ProductSearchMatch.corrected ||
      match == ProductSearchMatch.fuzzy;

  /// Null when the server sent none (a browse, or a server that predates it).
  static ProductSearchOutcome? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final matchName = json['match'];
    final match = ProductSearchMatch.values.firstWhere(
      (value) => value.name == matchName,
      orElse: () => ProductSearchMatch.exact,
    );
    final corrected = json['corrected_query'];
    final hidden = json['hidden_out_of_stock'];
    return ProductSearchOutcome(
      match: match,
      correctedQuery: corrected is String && corrected.trim().isNotEmpty
          ? corrected
          : null,
      hiddenOutOfStock: hidden is num ? hidden.toInt() : 0,
      categoryFallback: json['category_fallback'] == true,
    );
  }
}
