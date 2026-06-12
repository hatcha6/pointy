enum SalesChannelType {
  pos,
  delivery,
  ecommerce,
  marketplace,
  other;

  static SalesChannelType fromJson(Object? value) {
    return switch (value?.toString()) {
      'pos' => SalesChannelType.pos,
      'delivery' => SalesChannelType.delivery,
      'ecommerce' => SalesChannelType.ecommerce,
      'marketplace' => SalesChannelType.marketplace,
      _ => SalesChannelType.other,
    };
  }

  String toJson() => name;
}

class SalesChannel {
  const SalesChannel({
    required this.id,
    required this.name,
    required this.slug,
    required this.type,
    required this.isActive,
    required this.isSystem,
    required this.notes,
    required this.hasApiKey,
    required this.apiKeyPrefix,
    this.apiKeyGeneratedAt,
    this.apiKeyLastUsedAt,
  });

  final int id;
  final String name;
  final String slug;
  final SalesChannelType type;
  final bool isActive;
  final bool isSystem;
  final String notes;
  final bool hasApiKey;
  final String apiKeyPrefix;
  final DateTime? apiKeyGeneratedAt;
  final DateTime? apiKeyLastUsedAt;

  factory SalesChannel.fromJson(Map<String, Object?> json) {
    return SalesChannel(
      id: json['id'] as int,
      name: json['name']?.toString() ?? '',
      slug: json['slug']?.toString() ?? '',
      type: SalesChannelType.fromJson(json['channel_type']),
      isActive: json['is_active'] == true,
      isSystem: json['is_system'] == true,
      notes: json['notes']?.toString() ?? '',
      hasApiKey: json['has_api_key'] == true,
      apiKeyPrefix: json['api_key_prefix']?.toString() ?? '',
      apiKeyGeneratedAt: _dateTimeFromJson(json['api_key_generated_at']),
      apiKeyLastUsedAt: _dateTimeFromJson(json['api_key_last_used_at']),
    );
  }
}

class SalesChannelPage {
  const SalesChannelPage({required this.channels, required this.hasMore});

  final List<SalesChannel> channels;
  final bool hasMore;

  factory SalesChannelPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(SalesChannel.fromJson)
        .toList(growable: false);

    return SalesChannelPage(channels: results, hasMore: json['next'] != null);
  }
}

class SalesChannelDraft {
  const SalesChannelDraft({
    required this.name,
    required this.type,
    this.notes = '',
  });

  final String name;
  final SalesChannelType type;
  final String notes;

  Map<String, Object?> toJson() {
    return {'name': name, 'channel_type': type.toJson(), 'notes': notes};
  }
}

/// A channel response carrying the raw API key, returned exactly once by the
/// backend when a channel is created or its key is rotated.
class SalesChannelKeyGrant {
  const SalesChannelKeyGrant({required this.channel, required this.apiKey});

  final SalesChannel channel;
  final String apiKey;

  factory SalesChannelKeyGrant.fromJson(Map<String, Object?> json) {
    return SalesChannelKeyGrant(
      channel: SalesChannel.fromJson(json),
      apiKey: json['api_key']?.toString() ?? '',
    );
  }
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
