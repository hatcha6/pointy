class ProductImageSearchResult {
  const ProductImageSearchResult({
    required this.title,
    required this.thumbnailUrl,
    required this.sourceUrl,
    required this.sourceName,
    required this.provider,
    required this.importToken,
    this.width,
    this.height,
  });

  final String title;
  final String thumbnailUrl;
  final String sourceUrl;
  final String sourceName;
  final String provider;
  final String importToken;
  final int? width;
  final int? height;

  String get displayTitle => title.trim().isEmpty ? sourceName : title.trim();

  factory ProductImageSearchResult.fromJson(Map<String, Object?> json) {
    return ProductImageSearchResult(
      title: json['title']?.toString() ?? '',
      thumbnailUrl: json['thumbnail_url']?.toString() ?? '',
      sourceUrl: json['source_url']?.toString() ?? '',
      sourceName: json['source_name']?.toString() ?? '',
      provider: json['provider']?.toString() ?? '',
      importToken: json['import_token']?.toString() ?? '',
      width: _optionalIntFromJson(json['width']),
      height: _optionalIntFromJson(json['height']),
    );
  }
}

int? _optionalIntFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? '').toString());
}
