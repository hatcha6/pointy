class AttachmentSummary {
  const AttachmentSummary({
    required this.id,
    required this.originalFilename,
    required this.contentType,
    required this.contentUrl,
    required this.downloadUrl,
    this.isPrimary = false,
  });

  final int id;
  final String originalFilename;
  final String contentType;
  final String contentUrl;
  final String downloadUrl;
  final bool isPrimary;

  factory AttachmentSummary.fromJson(Map<String, Object?> json) {
    return AttachmentSummary(
      id: _intFromJson(json['id']),
      originalFilename: json['original_filename']?.toString() ?? '',
      contentType: json['content_type']?.toString() ?? '',
      contentUrl: json['content_url']?.toString() ?? '',
      downloadUrl: json['download_url']?.toString() ?? '',
      isPrimary: json['is_primary'] == true,
    );
  }
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}
