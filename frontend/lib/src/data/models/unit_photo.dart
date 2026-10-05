/// One photograph of an identified article: its condition record.
///
/// [thumbnailUrl] is a small server-made JPEG for strips and list rows;
/// [contentUrl] is the photo itself, for the full-screen viewer. Both carry a
/// signed token, so an image loader with no session can fetch them.
class UnitPhoto {
  const UnitPhoto({
    required this.id,
    required this.contentUrl,
    this.thumbnailUrl = '',
    this.isCover = false,
    this.originalFilename = '',
    this.createdAt,
    this.createdByUsername = '',
  });

  final int id;
  final String contentUrl;
  final String thumbnailUrl;

  /// The face the article shows first — on the till's picker and its page.
  final bool isCover;
  final String originalFilename;
  final DateTime? createdAt;
  final String createdByUsername;

  /// The small rendition when the server sent one, the photo otherwise.
  String get previewUrl => thumbnailUrl.isNotEmpty ? thumbnailUrl : contentUrl;

  UnitPhoto copyWith({bool? isCover}) => UnitPhoto(
    id: id,
    contentUrl: contentUrl,
    thumbnailUrl: thumbnailUrl,
    isCover: isCover ?? this.isCover,
    originalFilename: originalFilename,
    createdAt: createdAt,
    createdByUsername: createdByUsername,
  );

  factory UnitPhoto.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    return UnitPhoto(
      id: id is num ? id.toInt() : int.tryParse('$id') ?? 0,
      contentUrl: json['content_url']?.toString() ?? '',
      thumbnailUrl: json['thumbnail_url']?.toString() ?? '',
      isCover: json['is_cover'] == true,
      originalFilename: json['original_filename']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      createdByUsername: json['created_by_username']?.toString() ?? '',
    );
  }
}

/// A photo picked on this device, not yet sent.
class UnitPhotoUpload {
  const UnitPhotoUpload({
    required this.filename,
    required this.bytes,
    required this.contentType,
  });

  final String filename;
  final List<int> bytes;
  final String contentType;
}
