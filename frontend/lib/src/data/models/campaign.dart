/// Client-side mirror of the backend `Campaign` (apps.crm) and its preview.
enum CampaignStatus {
  draft,
  pendingApproval,
  approved,
  sending,
  sent,
  cancelled,
  failed,
  unknown,
}

CampaignStatus campaignStatusFromJson(Object? value) {
  return switch (value?.toString()) {
    'draft' => CampaignStatus.draft,
    'pending_approval' => CampaignStatus.pendingApproval,
    'approved' => CampaignStatus.approved,
    'sending' => CampaignStatus.sending,
    'sent' => CampaignStatus.sent,
    'cancelled' => CampaignStatus.cancelled,
    'failed' => CampaignStatus.failed,
    _ => CampaignStatus.unknown,
  };
}

class Campaign {
  const Campaign({
    required this.id,
    required this.name,
    required this.bodyTemplate,
    required this.status,
    this.rfmSegments = const [],
    this.totalRecipients = 0,
    this.sentCount = 0,
    this.failedCount = 0,
    this.skippedOptoutCount = 0,
    this.createdVia = 'human',
    this.createdAt,
  });

  final int id;
  final String name;
  final String bodyTemplate;
  final CampaignStatus status;
  final List<String> rfmSegments;
  final int totalRecipients;
  final int sentCount;
  final int failedCount;
  final int skippedOptoutCount;
  final String createdVia;
  final DateTime? createdAt;

  bool get isDraft =>
      status == CampaignStatus.draft ||
      status == CampaignStatus.pendingApproval;
  bool get isFromAi => createdVia == 'ai';

  factory Campaign.fromJson(Map<String, Object?> json) {
    final segments = json['rfm_segments'];
    return Campaign(
      id: _int(json['id']),
      name: json['name']?.toString() ?? '',
      bodyTemplate: json['body_template']?.toString() ?? '',
      status: campaignStatusFromJson(json['status']),
      rfmSegments: segments is List
          ? segments.map((e) => e.toString()).toList()
          : const [],
      totalRecipients: _int(json['total_recipients']),
      sentCount: _int(json['sent_count']),
      failedCount: _int(json['failed_count']),
      skippedOptoutCount: _int(json['skipped_optout_count']),
      createdVia: json['created_via']?.toString() ?? 'human',
      createdAt: _dateOrNull(json['created_at']),
    );
  }
}

/// The mutable draft payload for creating/updating a campaign.
class CampaignDraft {
  const CampaignDraft({
    required this.name,
    required this.bodyTemplate,
    this.rfmSegments = const [],
  });

  final String name;
  final String bodyTemplate;
  final List<String> rfmSegments;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'body_template': bodyTemplate,
      'rfm_segments': rfmSegments,
    };
  }
}

/// The pre-send preview: audience size, a rendered sample, and drip estimate.
class CampaignPreview {
  const CampaignPreview({
    required this.audienceTotal,
    required this.sendableEstimate,
    required this.skippedEstimate,
    required this.segments,
    required this.estimatedMinutes,
    required this.sampleMessage,
  });

  final int audienceTotal;
  final int sendableEstimate;
  final int skippedEstimate;
  final int segments;
  final int estimatedMinutes;
  final String sampleMessage;

  factory CampaignPreview.fromJson(Map<String, Object?> json) {
    return CampaignPreview(
      audienceTotal: _int(json['audience_total']),
      sendableEstimate: _int(json['sendable_estimate']),
      skippedEstimate: _int(json['skipped_estimate']),
      segments: _int(json['segments'], fallback: 1),
      estimatedMinutes: _int(json['estimated_minutes']),
      sampleMessage: json['sample_message']?.toString() ?? '',
    );
  }
}

int _int(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

DateTime? _dateOrNull(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) return null;
  return DateTime.tryParse(text);
}
