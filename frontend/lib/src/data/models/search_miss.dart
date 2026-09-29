/// A word someone searched the catalogue for and found nothing — one row of
/// the owner's «عمليات بحث بلا نتائج» worklist.
///
/// The server counts misses per folded word, so «ارز» and «أرز» are one row,
/// and lists the most typed first: a word asked for forty times a week is a
/// product the shop sells under a name its catalogue does not know yet.
/// Resolving a row teaches the catalogue that word as a name of the product
/// the owner picks, so the next search for it finds the product.
library;

int _toInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

DateTime? _toDate(Object? value) {
  final raw = value?.toString();
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}

enum SearchMissStatus {
  /// Still waiting for the owner.
  open,

  /// Taught to the catalogue as a name of [SearchMiss.productId].
  resolved,

  /// Set aside: a slip, or something the shop does not sell.
  dismissed;

  static SearchMissStatus fromJson(Object? value) {
    return switch (value?.toString()) {
      'resolved' => SearchMissStatus.resolved,
      'dismissed' => SearchMissStatus.dismissed,
      _ => SearchMissStatus.open,
    };
  }
}

/// Where the word was typed the most recent time.
enum SearchMissSurface {
  pos,
  catalog,
  purchasing,
  other;

  static SearchMissSurface fromJson(Object? value) {
    return switch (value?.toString()) {
      'pos' => SearchMissSurface.pos,
      'catalog' => SearchMissSurface.catalog,
      'purchasing' => SearchMissSurface.purchasing,
      _ => SearchMissSurface.other,
    };
  }
}

/// Which rows the worklist asks the server for.
enum SearchMissFilter {
  open('open'),
  resolved('resolved'),
  dismissed('dismissed'),
  all('all');

  const SearchMissFilter(this.apiValue);

  /// The `?status=` the server reads.
  final String apiValue;

  bool includes(SearchMissStatus status) {
    return switch (this) {
      SearchMissFilter.all => true,
      SearchMissFilter.open => status == SearchMissStatus.open,
      SearchMissFilter.resolved => status == SearchMissStatus.resolved,
      SearchMissFilter.dismissed => status == SearchMissStatus.dismissed,
    };
  }
}

class SearchMiss {
  const SearchMiss({
    required this.id,
    required this.term,
    this.normalized = '',
    this.surface = SearchMissSurface.other,
    this.count = 1,
    this.lastSeenAt,
    this.status = SearchMissStatus.open,
    this.productId,
    this.productName,
    this.resolvedAt,
  });

  final int id;

  /// As typed the most recent time.
  final String term;

  /// The folded form the server counts by.
  final String normalized;
  final SearchMissSurface surface;

  /// How many searches for it found nothing.
  final int count;
  final DateTime? lastSeenAt;
  final SearchMissStatus status;

  /// The product the owner said was meant, once resolved.
  final int? productId;
  final String? productName;
  final DateTime? resolvedAt;

  factory SearchMiss.fromJson(Map<String, Object?> json) {
    final product = json['product'];
    final productName = json['product_name']?.toString().trim() ?? '';
    return SearchMiss(
      id: _toInt(json['id']),
      term: json['term']?.toString() ?? '',
      normalized: json['normalized']?.toString() ?? '',
      surface: SearchMissSurface.fromJson(json['surface']),
      count: _toInt(json['count'], fallback: 1),
      lastSeenAt: _toDate(json['last_seen_at']),
      status: SearchMissStatus.fromJson(json['status']),
      productId: product == null ? null : int.tryParse(product.toString()),
      productName: productName.isEmpty ? null : productName,
      resolvedAt: _toDate(json['resolved_at']),
    );
  }
}

class SearchMissPage {
  const SearchMissPage({required this.misses, required this.hasMore});

  final List<SearchMiss> misses;
  final bool hasMore;

  factory SearchMissPage.fromAny(Object? decoded) {
    if (decoded is! Map) {
      return const SearchMissPage(misses: [], hasMore: false);
    }
    final results = decoded['results'];
    return SearchMissPage(
      misses: results is List
          ? [
              for (final row in results.whereType<Map>())
                SearchMiss.fromJson(
                  row.map((key, value) => MapEntry(key.toString(), value)),
                ),
            ]
          : const [],
      hasMore: decoded['next'] != null,
    );
  }
}
