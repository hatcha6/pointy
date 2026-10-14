/// An opening suggestion the assistant wrote for this shop: [title] is shown,
/// [prompt] is what tapping it sends.
class AiSuggestion {
  const AiSuggestion({
    required this.title,
    required this.prompt,
    this.icon = 'idea',
  });

  final String title;
  final String prompt;
  final String icon;

  static List<AiSuggestion> listFrom(Object? raw) {
    if (raw is! List) {
      return const [];
    }
    return [
      for (final item in raw)
        if (item is Map && '${item['title'] ?? ''}'.trim().isNotEmpty)
          AiSuggestion(
            title: '${item['title']}'.trim(),
            prompt: '${item['prompt'] ?? item['title']}'.trim(),
            icon: '${item['icon'] ?? 'idea'}',
          ),
    ];
  }
}

/// Something the assistant remembers about the shop, or about one user, and
/// carries into every later conversation.
class AiMemory {
  const AiMemory({
    required this.id,
    required this.content,
    required this.isShop,
    this.category = 'other',
    this.editable = false,
    this.updatedAt,
  });

  final int id;
  final String content;

  /// Shared by everyone's assistant; false for a user's personal memory.
  final bool isShop;
  final String category;

  /// Whether this user may change it — their own notes always, shop notes only
  /// as a manager. Decided by the server.
  final bool editable;
  final DateTime? updatedAt;

  AiMemory copyWith({String? content}) => AiMemory(
    id: id,
    content: content ?? this.content,
    isShop: isShop,
    category: category,
    editable: editable,
    updatedAt: updatedAt,
  );

  factory AiMemory.fromJson(Map<String, Object?> json) => AiMemory(
    id: (json['id'] as num?)?.toInt() ?? 0,
    content: (json['content'] as String?) ?? '',
    isShop: json['scope'] != 'user',
    category: (json['category'] as String?) ?? 'other',
    editable: json['editable'] == true,
    updatedAt: DateTime.tryParse('${json['updated_at'] ?? ''}'),
  );
}
